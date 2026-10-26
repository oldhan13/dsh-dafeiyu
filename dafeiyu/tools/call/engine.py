"""通话引擎：和「声音从哪来、到哪去」无关的那一半。

    Ear    任意来源的 PCM（float32 单声道 @16k，块大小随意）→ VAD 切句
    Brain  DeepSeek（电话模式：短、口语、不排版）
    Mouth  TTS 流式合成 → 一块一块交给 sink（写声卡 / 发给浏览器 都行）

三个宿主共用它：
    petcall.py  默认麦克风 → 默认扬声器     （桌宠上的通话窗）
    webcall.py  浏览器 WebSocket 上下行      （网页通话）
    loop.py     环回扬声器 → CABLE Input    （QQ 原生通话那条，暂时缺宿主）

为什么抽出来：这三种「通话」的差别**只在出入口**，中间那套听→想→说、以及
打断（barge-in），一模一样。写三份就是三份要各自调参的延迟。

用法：
    from engine import CallEngine, MicSource, SpeakerSink
    eng = CallEngine(on_event=print)
    eng.start()
    MicSource(eng.feed).start()
"""

from __future__ import annotations

import json
import os
import queue
import sys
import re
import threading
import time
import warnings

import numpy as np

# SoundCard 在 Windows 上隔一会儿就喊一次 discontinuity —— 话筒短暂断流时的正常现象
warnings.filterwarnings("ignore", message="data discontinuity in recording")

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

# ---------------------------------------------------------------- 参数
# 前五项抄自 ohwhale-deploy/scripts/call_loop.py 的实测值（理由见 listen.py 文件头）
RATE = 16000                # 引擎内部一律 16k 单声道
FRAME = 0.05                # VAD 步长
SILENCE_END = 0.90          # 静这么久就算说完了（短了会截断，长了显拖）
MIN_SPEECH = 0.25           # 再短的就当咳嗽
MAX_UTTER = 18.0            # 一口气超过这个就强制断开
PREROLL = 0.45              # 回补：切句点之前留一点，别把第一个字吃掉
THRESHOLD_FLOOR = 0.009     # 绝对地板，安静房间也能开口
NOISE_MULT = 2.2            # 或者噪声底的 2.2 倍
BARGE_MIN_SPEECH = 0.30     # 她说话时对方要连续响 0.3s 才算打断
BARGE_RATIO = 2.0

HISTORY_MAX = 24            # 只带最近若干轮进上下文

# ★ 2026-10-26 20:2x：`{maxchars}` 是从 state/call/config.json 的 `call.max_reply_chars`
#   填进来的。原来这里写死「不超过 25 个字」，而界面上那个「一句最多几个字」的框
#   **改了没有任何地方读它** —— 又一个会说谎的控件（跟云端那个写死 voice 是同一类）。
SYSTEM = (
    "你在跟主人打电话，声音是直接送到他耳朵里的。\n"
    "**说人话，别说稿子**：一次一到两句，总共不超过 {maxchars} 个字。\n"
    "句子长短错开 —— 有时两个字（「嗯」「是吗」），有时一整句。\n"
    "可以带语气词（嗯、啊、呗、欸、哈哈），可以有停顿（用逗号表示），"
    "可以有情绪（他累你就软一点，他逗你就接住）。\n"
    "不要列表、不要加粗、不要括号里的旁白、不要念表情符号、不要客套话。\n"
    "听不清就直说听不清，不要瞎猜。\n"
    "★ 如果他让你**动这台电脑**（打开程序、关掉什么、截图、查内存/磁盘/文件、写或改一个文件、"
    "搜东西、发消息……），你不要自己编结果 —— 整个回复只写一个记号：[[电脑]]\n"
    "  那一句会被转给能真正操作电脑的那条路，她的回答再由你的声音念出来。"
)

_MARK = "[[电脑]]"


def _call_context() -> str:
    """给通话那一路一点**真上下文**：现在几点、他是谁、最近几天发生了什么。

    ★ 2026-10-26 21:4x（他说「语音的内容接入上下文和 agent」）：从前这段 SYSTEM
      是**空的** —— 打电话的她只知道「在打电话」，不知道主人今天在折腾什么，
      所以会说出「我这儿看不到你电脑的情况呀」这种话。现在把开场简报（`memory/brief.md`，
      每 30 分钟自己重写一份）和当前时间带上。
    """
    parts = []
    try:
        parts.append("现在是 " + time.strftime("%Y-%m-%d %H:%M") + "。")
    except Exception:  # noqa: BLE001
        pass
    p = os.path.join(HERE, "..", "..", "memory", "brief.md")
    try:
        with open(p, "r", encoding="utf-8-sig") as f:
            t = f.read().strip()
        if t:
            parts.append("（下面是你的开场简报，用作背景，不要照着念）\n" + t[:1800])
    except OSError:
        pass
    return "\n\n".join(parts)


def desk_ask(text: str, wait: float = 45.0) -> str:
    """把这句话交给桌面那条 agent（有记忆、有工具），等它的回答。

    ★ 只走已经存在的 `/say`：那条路上的工具、人格、上下文都是现成的，
      不新开接口，也不在两处各维护一份。返回空串 = 没等到（对方没起 / 跑太久）。
    """
    import urllib.request

    hist = os.path.join(HERE, "..", "..", "desk", "history.jsonl")
    pos = -1
    try:
        with open(hist, "rb") as f:
            f.seek(0, os.SEEK_END)
            pos = f.tell()
    except OSError:
        pos = -1
    body = json.dumps({"text": text, "quiet": True}).encode("utf-8")
    headers = {"Content-Type": "application/json"}
    try:
        with open(os.path.join(HERE, "..", "..", "desk", "token.txt"), "r", encoding="utf-8") as f:
            headers["x-dfy-token"] = f.read().strip()
    except OSError:
        pass
    req = urllib.request.Request("http://127.0.0.1:3079/say", data=body, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            r.read()
    except Exception as e:  # noqa: BLE001
        log(f"[电脑] 交给桌面那条路失败：{type(e).__name__}: {e}")
        return ""
    if pos < 0:
        return ""
    end = time.time() + wait
    while time.time() < end:
        time.sleep(0.4)
        try:
            with open(hist, "rb") as f:
                f.seek(pos)
                chunk = f.read().decode("utf-8", "replace")
        except OSError:
            continue
        for line in chunk.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                o = json.loads(line)
            except ValueError:
                continue
            if o.get("role") == "assistant":
                t = str(o.get("text") or "").strip()
                if t:
                    return t
    return ""


def speech_clip(text: str, limit: int = 80) -> str:
    """念出来的话别太长：按句子截到 limit 个字符左右。"""
    t = " ".join(str(text or "").split())
    if len(t) <= limit:
        return t
    cut = 0
    for i, ch in enumerate(t[:limit]):
        if ch in "。！？!?，,；;":
            cut = i + 1
    return (t[:cut] if cut else t[:limit]).rstrip()


def _call_cfg() -> dict:
    """通话手感（什么时候算说完 / 一句几个字 / 让不让壁纸退场）从配置读。

    读不到就用文件头上那几个常量 —— 这一条是兜底，不是常态。
    """
    try:
        import config as cfgmod
        return cfgmod.load().get("call") or {}
    except Exception:  # noqa: BLE001
        return {}

KEYFILE = os.path.expanduser(r"~\.dsh\deepseek-key.txt")


def log(msg: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def normalize(audio: np.ndarray) -> np.ndarray:
    amp = float(np.max(np.abs(audio))) if len(audio) else 0.0
    if amp > 0.001:
        gain = min(8.0, 0.6 / amp)
        if gain > 1.2:
            return np.clip(audio * gain, -1.0, 1.0)
    return audio


def _as_float32(x) -> np.ndarray:
    a = np.asarray(x)
    if a.ndim > 1:
        a = a.mean(axis=1)
    a = a.ravel()
    if a.dtype == np.int16:
        return (a.astype(np.float32) / 32768.0)
    return a.astype(np.float32, copy=False)


# ---------------------------------------------------------------- 大脑

def _api_key() -> str:
    with open(KEYFILE, "r", encoding="utf-8") as f:
        return f.read().strip()


def brain_say(history: list[dict], system: str | None = None,
              model: str = "deepseek-chat", timeout: float = 20.0) -> tuple[str, float]:
    import urllib.request

    if system is None:
        system = SYSTEM.format(maxchars=25)
    body = json.dumps({
        "model": model,
        "messages": [{"role": "system", "content": system}] + history,
        "temperature": 0.8,
        "max_tokens": 160,
    }).encode("utf-8")
    req = urllib.request.Request(
        "https://api.deepseek.com/v1/chat/completions",
        data=body,
        headers={"Content-Type": "application/json", "Authorization": "Bearer " + _api_key()},
    )
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=timeout) as r:
        j = json.loads(r.read().decode("utf-8"))
    took = (time.time() - t0) * 1000
    text = (j.get("choices") or [{}])[0].get("message", {}).get("content", "").strip()
    return text, took


# ---------------------------------------------------------------- 出口缓冲

class JitterPlayer:
    """把「生成」和「播放」拆成两条线，中间垫一小段缓冲。

    ★ 2026-10-26 20:4x 量出来的（他原话：「主要问题是声音卡顿，听感很不好，
      QQ 单独发的语音就还行」）：

      sovits 的出块是**突发式**的。实测三个句子，一句话中间会出现
      **841 / 860 / 594 / 590 / 573 ms 的停顿**（`C:\\dsh-temp\\chunk-gaps.py` 量的）。
      整句算下来的 RTF 只有 0.6 —— **平均够快，节奏是错的**：
      播放端按 1.0 倍速放，缓冲一空就是一声卡。

      而 QQ 那条路为什么好？因为它是「整段合成完再播」，根本没有中间的空档。

      ⇒ 这里先攒够 `cushion` 秒再开口，之后边放边收。真的追不上就等它，
        但 cushion 会自己变大（这一句饿过 ⇒ 下一句多垫 0.25s，最多 1.2s），
        所以「越聊越顺」，不用人去调参数。
    """

    def __init__(self, sink, rate: int, cushion: float = 0.35,
                 t0: float | None = None, min_piece: float = 0.08,
                 fade: float = 0.005):
        self.sink = sink
        self.rate = max(1, int(rate))
        self.cushion = float(cushion)
        self.min_piece = float(min_piece)
        self.fade = float(fade)          # 接缝淡入淡出的长度（秒）
        self._buf: list[np.ndarray] = []
        self._n = 0
        self._done = False
        self._abort = False
        self._cv = threading.Condition()
        self._thread = None
        self._t0 = t0 if t0 is not None else time.time()
        self.starved = False        # 这一句有没有饿过
        self.fades = 0              # 做了几次淡入淡出（听感排查用）
        self.played = 0             # 真正交给 sink 的采样数
        self.first_at = None        # 第一次出声的时刻（相对 t0，秒）

    def start(self) -> "JitterPlayer":
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()
        return self

    def push(self, arr) -> None:
        if arr is None or not len(arr):
            return
        a = np.asarray(arr, dtype="float32").ravel()
        with self._cv:
            if self._abort:
                return
            self._buf.append(a)
            self._n += len(a)
            self._cv.notify_all()

    def finish(self) -> None:
        with self._cv:
            self._done = True
            self._cv.notify_all()

    def abort(self) -> None:
        with self._cv:
            self._abort = True
            self._buf.clear()
            self._n = 0
            self._cv.notify_all()

    def wait(self, timeout: float = 0.05) -> bool:
        """等它放完。True = 已经结束（正常放完或被掐掉）。"""
        if self._thread is None:
            return True
        self._thread.join(timeout)
        return not self._thread.is_alive()

    def _run(self) -> None:
        need = int(self.cushion * self.rate)
        min_n = max(1, int(self.min_piece * self.rate))
        fade_n = max(1, int(self.fade * self.rate))
        started = False
        starving = False
        resume = True                       # 第一块也淡入：从静音里开口不该是一步跳上去
        while True:
            with self._cv:
                if not started:
                    # 先垫够再开口：这一步就是「不卡」的全部秘密
                    while not self._abort and not self._done and self._n < need:
                        self._cv.wait(0.05)
                    started = True
                while not self._abort and not self._buf and not self._done:
                    if not starving:
                        starving = True
                        self.starved = True
                    self._cv.wait(0.02)
                if starving:
                    # 缓冲饿空过 ⇒ 声音是从静音里突然接上的。
                    # ★ 2026-10-26 20:5x 他报「播放时有爆破声/电流声」，量的就是这个：
                    #   模拟合成端停顿 0.7s，用真扬声器录回来，接缝处有一步 **0.32** 的跳变
                    #   （纯音自己每步只有 0.01）—— 一步跳变就是一声「啪」。
                    #   所以断过之后的第一块淡入，说完的最后一块淡出，把台阶换成斜坡。
                    resume = True
                starving = False
                if self._abort:
                    return
                if not self._buf:
                    return                      # 已经说完且放完了
                # 攒到至少 min_piece 再送出去：太碎的块反而更容易抖
                take = []
                got = 0
                while self._buf and got < min_n:
                    a = self._buf.pop(0)
                    take.append(a)
                    got += len(a)
                self._n -= got
                last = self._done and not self._buf
            piece = take[0] if len(take) == 1 else np.concatenate(take)
            if len(piece) > fade_n * 2:
                if resume:
                    piece = piece.copy()
                    piece[:fade_n] *= np.linspace(0.0, 1.0, fade_n, dtype="float32")
                    resume = False
                    self.fades += 1
                if last:
                    piece = piece.copy()
                    piece[-fade_n:] *= np.linspace(1.0, 0.0, fade_n, dtype="float32")
                    self.fades += 1
            if self.first_at is None:
                self.first_at = time.time() - self._t0
            if self.sink is not None:
                try:
                    self.sink(piece, self.rate)
                except Exception as e:  # noqa: BLE001
                    log(f"[播放] 出错：{type(e).__name__}: {e}")
                    return
            self.played += len(piece)


def squeeze_silence(x: np.ndarray, rate: int, floor: float = 0.012,
                    min_ms: int = 180) -> np.ndarray:
    """把句子中间那些「白」压短。

    ★ 2026-10-26 21:4x：整段交给模型之后（并行、快），它自己会在标点处停
      350~880ms —— 那正是他说的「卡」。这截白在音频里是**静音**，所以处理起来
      最安全：只在静音段上动刀，不动任何有声的样点（不会引入咔哒）。
      ≥400ms 的留 160ms（像句号），其余留 80ms（像换气）。
    """
    w = max(1, int(0.01 * rate))
    n = len(x) // w
    if n < 5:
        return x
    env = np.sqrt(np.mean(x[:n * w].reshape(n, w) ** 2, axis=1))
    peak = float(np.max(env)) or 1.0
    quiet = env < max(floor, peak * 0.02)
    out: list[np.ndarray] = []
    last = 0
    i = 0
    while i < n:
        if not quiet[i]:
            i += 1
            continue
        j = i
        while j < n and quiet[j]:
            j += 1
        dur_ms = (j - i) * 10
        if dur_ms >= min_ms:
            keep = 210 if dur_ms >= 400 else 115
            out.append(x[last:i * w])
            out.append(np.zeros(max(1, int(keep / 1000.0 * rate)), dtype="float32"))
            last = j * w
        i = j
    out.append(x[last:])
    return np.concatenate(out)


# ---------------------------------------------------------------- 引擎

class CallEngine:
    """喂 PCM 进去，收事件和「她说的话」出来。线程安全：feed() 随便哪个线程都能调。

    事件（on_event 回调，dict，都有 t 字段）：
        state       state: idle|listening|thinking|speaking
        level       level: 0..1 量化的输入音量（给界面画波形）
        heard       text: 对方说了什么
        reply       text: 她准备说什么
        say_start   rate: 采样率（下面的音频块就是这个采样率）
        say_end     interrupted: bool
        error       msg

    音频出口：sink(chunk: np.ndarray, rate: int)。
    """

    def __init__(self, asr=None, tts_backend: str | None = None, tts_engine=None,
                 sink=None, on_event=None, system: str | None = None,
                 model: str = "deepseek-chat", seed: list[dict] | None = None,
                 verbose: bool = True):
        # 不指定就按 state/call/config.json 里选的（界面切的就是它）
        if not tts_backend:
            try:
                import config as cfgmod
                tts_backend = cfgmod.backend()
            except Exception:  # noqa: BLE001
                tts_backend = "piper"

        # ★ 通话手感也从那份配置来（`call.silence_end` / `call.max_reply_chars`）。
        #   从前这两个框改了不生效 —— 跟云端那个写死 voice 是同一种毛病，一起修掉。
        ccfg = _call_cfg()
        try:
            self.silence_end = float(ccfg.get("silence_end") or SILENCE_END)
        except (TypeError, ValueError):
            self.silence_end = SILENCE_END
        self.silence_end = min(4.0, max(0.25, self.silence_end))
        try:
            maxchars = int(ccfg.get("max_reply_chars") or 25)
        except (TypeError, ValueError):
            maxchars = 25
        maxchars = min(120, max(8, maxchars))

        self.asr = asr
        self.tts_backend = tts_backend
        self.tts_engine = tts_engine
        self.sink = sink
        self.on_event = on_event
        self.system = system if system else SYSTEM.format(maxchars=maxchars)
        if not system:
            ctx = _call_context()
            if ctx:
                self.system = self.system + "\n\n" + ctx
        self.model = model
        self.verbose = verbose

        self.history: list[dict] = list(seed or [])
        self.state = "idle"
        self.level = 0.0
        # 播放缓冲的垫子（秒）。JitterPlayer 会按「这一句饿没饿过」自己调它。
        self._cushion = 0.35

        self._q: queue.Queue = queue.Queue(maxsize=64)     # 切好句的音频
        self._stop = threading.Event()
        self._speaking = threading.Event()
        self._abort = threading.Event()                    # 打断当前这句
        self._thread = None
        self._lock = threading.Lock()                      # VAD 状态只在这一把锁里动
        self._last_frame = time.monotonic()
        self._last_level = 0.0

        # VAD 状态（只在 feed 所在线程动）
        self._noise = 0.005
        self._pre: list[np.ndarray] = []
        self._buf: list[np.ndarray] = []
        self._speech = 0.0
        self._silence = 0.0
        self._loud = 0.0
        self._pre_len = max(1, int(PREROLL / FRAME))

        # 统计
        self.turns: list[dict] = []
        self.started_at = time.time()

    # ---------------- 事件
    def emit(self, t: str, **kw) -> None:
        if self.on_event is None:
            return
        try:
            self.on_event(dict(t=t, **kw))
        except Exception as e:  # noqa: BLE001
            log(f"[事件回调出错] {type(e).__name__}: {e}")

    def _set_state(self, s: str) -> None:
        if s != self.state:
            self.state = s
            self.emit("state", state=s)

    # ---------------- 生命期
    def start(self) -> "CallEngine":
        if self._thread is None:
            self._thread = threading.Thread(target=self._worker, daemon=True)
            self._thread.start()
            self._set_state("listening")
        return self

    def stop(self) -> None:
        self._stop.set()
        self._abort.set()
        if self._thread is not None:
            self._thread.join(timeout=5)
        self._set_state("idle")

    # ---------------- 入口：喂音频
    def feed(self, frames) -> None:
        """frames: float32/int16 单声道 @16k。块大小随意，内部按 FRAME 切。"""
        sig = _as_float32(frames)
        if not len(sig):
            return
        step = int(RATE * FRAME)
        for i in range(0, len(sig), step):
            with self._lock:
                self._frame(sig[i:i + step])

    def _tick(self) -> None:
        """没声音进来时也得能把最后一句切掉 —— 否则「说完就挂断/断线」那一句永远不出来。"""
        with self._lock:
            if self._speech > 0 and (time.monotonic() - self._last_frame) > (self.silence_end + 0.25):
                self._close()

    def _frame(self, sig: np.ndarray) -> None:
        if len(sig) < 8:
            return
        self._last_frame = time.monotonic()
        rms = float(np.sqrt(np.mean(sig ** 2)))
        dur = len(sig) / RATE
        self.level = rms
        if rms < self._noise:
            self._noise = 0.98 * self._noise + 0.02 * rms
        thr = max(THRESHOLD_FLOOR, self._noise * NOISE_MULT)

        speaking = self._speaking.is_set()
        if speaking:
            # 打断：她说话时，对方得「明显更响」而且持续一小段
            if rms > max(thr * BARGE_RATIO, THRESHOLD_FLOOR * 3):
                self._loud += dur
                if self._loud >= BARGE_MIN_SPEECH and not self._abort.is_set():
                    log("[打断] 对方开口了，掐掉这一句")
                    self._abort.set()
            else:
                self._loud = 0.0
        else:
            self._loud = 0.0

        if rms > thr:
            if self._speech == 0.0:
                self._buf = list(self._pre)
            self._buf.append(sig.copy())
            self._speech += dur
            self._silence = 0.0
        elif self._speech > 0:
            self._buf.append(sig.copy())
            self._silence += dur
            if self._silence >= self.silence_end:
                self._close()
        else:
            now = time.monotonic()
            if now - self._last_level > 0.12:      # 限流：每秒十来次就够界面用了
                self._last_level = now
                self.emit("level", level=min(1.0, rms * 12))

        if self._speech > MAX_UTTER and self._buf:
            self._close()

        self._pre.append(sig.copy())
        if len(self._pre) > self._pre_len:
            self._pre.pop(0)

    def _close(self) -> None:
        if self._speech >= MIN_SPEECH:
            audio = np.concatenate(self._buf) if self._buf else None
            if audio is not None and len(audio):
                try:
                    self._q.put_nowait(audio)
                except queue.Full:
                    try:
                        self._q.get_nowait()
                    except queue.Empty:
                        pass
                    self._q.put_nowait(audio)
        self._buf, self._speech, self._silence = [], 0.0, 0.0

    def inject(self, audio) -> None:
        """不理 VAD，直接把一段音频当成「对方说的一句话」塞进来（自测用）。"""
        self._q.put(_as_float32(audio))

    # ---------------- 出口：听 → 想 → 说
    def _worker(self) -> None:
        while not self._stop.is_set():
            try:
                audio = self._q.get(timeout=0.4)
            except queue.Empty:
                self._tick()
                continue
            if self._stop.is_set():
                return
            try:
                self._turn(audio)
            except Exception as e:  # noqa: BLE001
                log(f"[环] 这一轮出错：{type(e).__name__}: {e}")
                self.emit("error", msg=f"{type(e).__name__}: {e}")
                self._set_state("listening")

    def _turn(self, audio: np.ndarray) -> None:
        dur = len(audio) / RATE
        self._set_state("thinking")
        heard = self.asr.transcribe(normalize(audio)) if self.asr else ""
        asr_ms = getattr(self.asr, "last_ms", 0.0) or 0.0
        turn = {"at": round(time.time() - self.started_at, 2), "audio_s": round(dur, 2),
                "asr_ms": round(asr_ms), "heard": heard}

        if not heard or not heard.strip("，。？！,.?! "):
            if self.verbose:
                log(f"[耳] {dur:.1f}s → 空转写，跳过")
            self.turns.append(turn)
            self._set_state("listening")
            return
        self.emit("heard", text=heard)
        if self.verbose:
            log(f"对方：{heard}   （音频 {dur:.1f}s · ASR {asr_ms:.0f}ms）")

        self.history.append({"role": "user", "content": heard})
        # ★ 从前 history 只增不减（虽然每次只把最后 24 条喂给模型）——
        #   一通两小时的电话能攒下几百轮，白占着不放。现在攒到两倍就掐掉最前面的。
        if len(self.history) > HISTORY_MAX * 2:
            del self.history[:len(self.history) - HISTORY_MAX * 2]
        reply, brain_ms = brain_say(self.history[-HISTORY_MAX:], self.system, self.model)
        turn["brain_ms"] = round(brain_ms)
        # ★ 2026-10-26 21:5x：要真动电脑的那一句，转给桌面那条 agent（有工具、有记忆），
        #   她的回答再拿回来念。判据是模型自己给的记号，不用正则去猜「这算不算命令」。
        if _MARK in reply:
            said = reply.replace(_MARK, "").strip()
            if self.verbose:
                log("[电脑] 这句要真动手 —— 交给桌面那条 agent")
            self._set_state("thinking")
            t_desk = time.time()
            got = desk_ask(heard)
            turn["desk_ms"] = round((time.time() - t_desk) * 1000)
            reply = speech_clip(got) if got else (said or "我还在弄，等一会儿再跟你说")
            if self.verbose:
                log(f"[电脑] 回来 {len(got)} 字（{turn['desk_ms']}ms）")
        turn["reply"] = reply
        self.history.append({"role": "assistant", "content": reply})
        if len(self.history) > HISTORY_MAX * 2:
            del self.history[:len(self.history) - HISTORY_MAX * 2]
        # 记号类的残留一律不许念出来（不然她会把「[[电脑]]」当字读给你听）
        reply = re.sub(r"\[\[.*?\]\]", "", reply).strip()
        if not reply:
            self.turns.append(turn)
            self._set_state("listening")
            return
        self.emit("reply", text=reply)
        if self.verbose:
            log(f"我：{reply}   （大脑 {brain_ms:.0f}ms）")

        # ---- 说
        import tts as ttsmod
        self._abort.clear()
        self._loud = 0.0
        stats: dict = {}
        t_tts = time.time()
        try:
            tts_rate, it = ttsmod.make_stream(self.tts_backend, reply,
                                              engine=self.tts_engine, stats=stats)
        except Exception as e:  # noqa: BLE001
            # 先自救：sovits 那个常驻进程可能被关掉了（关机 / 手动 kill / OOM）
            recovered = False
            if self.tts_backend == "sovits":
                try:
                    if ttsmod.ensure_sovits(timeout=45.0):
                        tts_rate, it = ttsmod.make_stream("sovits", reply, stats=stats)
                        recovered = True
                except Exception:  # noqa: BLE001
                    recovered = False
            if not recovered:
                # sovits 起不来 / cloud 没 key —— 别让这一通电话直接哑掉，退回本地 piper
                if self.verbose:
                    log(f"[TTS] {self.tts_backend} 不可用（{type(e).__name__}: {e}），退回 piper")
                self.tts_backend = "piper"
                if self.tts_engine is None:
                    self.tts_engine = ttsmod.piper_from_config()
                tts_rate, it = ttsmod.make_stream("piper", reply,
                                                  engine=self.tts_engine, stats=stats)
        self._speaking.set()
        self._set_state("speaking")
        # ⚠️ `say_start` 是「声音开始出来」的信号（界面靠它切状态），必须放在**攒齐之后**发，
        #    不然窗口会显示「她在说」而其实还在合成 —— 那就是个会说谎的指示器。
        # ★★ 2026-10-26 21:1x（他第三次说：「不是音频合成的问题，是播放的问题，播放的时候卡了」）
        #
        #   量到最后一步才看清：**播放这一侧是干净的**。`underrun-probe.py` 一边放
        #   一段已经拿在手里的纯音、一边每 2ms 问一次声卡 `GetCurrentPadding` ——
        #   32k / 44.1k / 48k、缓冲 47ms 和 120ms 都一样：**中途一次都没空**（只在开头那一下）。
        #   所以「卡」不是缓冲空，是**音频还没到手就开播**：她一边说、服务端一边合成，
        #   拍子天然比播放慢，声卡那点缓冲垫不住 → 听起来就是播放卡住。
        #
        #   而 QQ 单发语音为什么好听？因为它是**整段合成完再播**，中间根本没有「还没到」。
        #   ⇒ 那就照它来：**先把这一整句拿到手，再开播**（他说过卡顿比多等一会儿难受得多）。
        #     代价是开口晚 ~1s（首块 0.9~1.4s + 剩下的合成），换播放一个洞都没有。
        chunks: list[np.ndarray] = []
        t_collect = time.time()
        try:
            try:
                for ch in it:
                    if self._abort.is_set() or self._stop.is_set():
                        break
                    chunks.append(np.asarray(ch, dtype="float32").ravel())
            except Exception as e:  # noqa: BLE001
                # 生成到一半断了（sovits 掉线 / 网络抖）——**别把她说到一半的话掐掉**，
                # 把已经攒下的放完，再记一笔。
                log(f"[TTS] 生成中断（{type(e).__name__}: {e}），已收到的照常说完")
            # ★ 2026-10-26 20:5x：打断时只是 break 出循环，生成器要等这一轮结束才被
            #   回收 —— 那段时间服务端还在为一个没人听的请求合成，而它的 SPEAK_LOCK
            #   是全局的，下一句得排队（实测多等 456ms，通话里就是「该说话了还没声」）。
            #   显式关掉连接，服务端立刻收手。
            try:
                it.close()
            except Exception:  # noqa: BLE001
                pass
        finally:
            pass
        collect_ms = (time.time() - t_collect) * 1000
        # 整句已在手 ⇒ 垫子只要一小截（留 120ms 给线程调度，不再是「等音频」）
        audio = (np.concatenate(chunks) if chunks else np.zeros(0, dtype="float32"))
        before_s = len(audio) / max(1, tts_rate)
        audio = squeeze_silence(audio, tts_rate)
        squeezed_ms = (before_s - len(audio) / max(1, tts_rate)) * 1000
        self.emit("say_start", rate=tts_rate)
        player = JitterPlayer(self.sink, tts_rate, cushion=0.12, t0=t_tts).start()
        try:
            player.push(audio)
            player.finish()
            while not player.wait(0.05):
                if self._abort.is_set() or self._stop.is_set():
                    player.abort()
                    break
        finally:
            if not player.wait(0.05):
                player.abort()
            self._speaking.clear()
            self.emit("say_end", interrupted=self._abort.is_set())

        # ★ 整句先到手再播 ⇒ 「饿」这件事在结构上不会发生了；`starved` 只当作断言留着，
        #   它要是又变 true，说明真出问题了（不是正常的尾部判断）。
        first_ms = (player.first_at * 1000) if player.first_at is not None else None
        played_samples = player.played

        tts_ms = (time.time() - t_tts) * 1000
        turn.update({
            "tts_backend": self.tts_backend,
            "tts_ms": round(tts_ms),
            "tts_first_audio_ms": round(first_ms or 0),
            "played_s": round(played_samples / max(1, tts_rate), 2),
            "interrupted": self._abort.is_set(),
            "first_sound_ms": round(asr_ms + brain_ms + (collect_ms + (first_ms or 0))),
            # 听感的现场证据：整句攒齐花了多久、播的时候有没有饿过
            "collect_ms": round(collect_ms),
            "cushion_s": 0.12,
            "starved": bool(player.starved),
            "fades": int(player.fades),
        })
        self.turns.append(turn)
        if self.verbose:
            log(f"[环] 说完 {turn['played_s']:.2f}s · **开口延迟 {turn['first_sound_ms']}ms**"
                f"（识别 {asr_ms:.0f} + 想 {brain_ms:.0f} + TTS 首块 {turn['tts_first_audio_ms']}）")
        self._set_state("listening")

    # ---------------- 让旁边的人知道进度
    def snapshot(self) -> dict:
        return {
            "state": self.state,
            "level": round(min(1.0, self.level * 12), 3),
            "turns": len(self.turns),
            "last": self.turns[-1] if self.turns else None,
        }


# ---------------------------------------------------------------- 出入口

class MicSource(threading.Thread):
    """从真实麦克风（或环回）读，喂给 engine.feed。"""

    def __init__(self, feed, device_hint: str | None = None, loopback: bool = False):
        super().__init__(daemon=True)
        self.feed = feed
        self.loopback = loopback
        self.device_hint = device_hint
        self.stop_flag = threading.Event()
        self.name_ = "?"

    def _pick(self):
        import soundcard as sc
        if self.device_hint:
            hint = self.device_hint.lower()
            if self.loopback:
                spk = next((s for s in sc.all_speakers() if hint in s.name.lower()), None)
                if spk is None:
                    raise RuntimeError(f"找不到要环回的播放端点（含 {self.device_hint}）")
                return sc.get_microphone(id=str(spk.name), include_loopback=True)
            for m in sc.all_microphones(include_loopback=False):
                if hint in m.name.lower():
                    return m
            for m in sc.all_microphones(include_loopback=True):
                if hint in m.name.lower() and getattr(m, "isloopback", False):
                    return m
            raise RuntimeError(f"找不到录音端点（含 {self.device_hint}）")
        if self.loopback:
            spk = sc.default_speaker()
            return sc.get_microphone(id=str(spk.name), include_loopback=True)
        return sc.default_microphone()

    def run(self) -> None:
        import soundcard as sc
        try:
            mic = self._pick()
            self.name_ = mic.name
            log(f"[耳] {mic.name}")
            n = int(RATE * FRAME)
            with mic.recorder(samplerate=RATE, channels=1) as rec:
                while not self.stop_flag.is_set():
                    self.feed(rec.record(numframes=n))
        except Exception as e:  # noqa: BLE001
            log(f"[耳] 采集退出：{type(e).__name__}: {e}")

    def stop(self) -> None:
        self.stop_flag.set()


class SpeakerSink:
    """把她的声音写到某个播放端点。分小块播，好让打断能在半句上生效。

    ▼ 注意：写声卡是阻塞的，引擎在 worker 线程里调它，所以说话期间 feed() 照常工作
      （打断靠的就是这一点）。
    """

    def __init__(self, device_hint: str | None = None, replace_rate: int | None = None,
                 buffer_s: float = 0.12):
        import soundcard as sc
        if device_hint:
            hint = device_hint.lower()
            self.spk = next((s for s in sc.all_speakers() if hint in s.name.lower()), None)
            if self.spk is None:
                raise RuntimeError(f"找不到播放端点（含 {device_hint}）")
        else:
            self.spk = sc.default_speaker()
        self.replace_rate = replace_rate
        # ★ 2026-10-26 20:5x：soundcard 默认的 blocksize 是「一个设备周期」
        #   （这台机器上 ≈10ms）。10ms 的声卡缓冲意味着**只要 Python 这一侧被
        #   卡住 10ms 以上，声卡那头就空了** —— 而通话时同进程里还有 whisper、
        #   还有 GDI+ 的重画、还有 GIL 抢。空一下再续上，接缝就是一声「啪」。
        #   缓存给到 120ms 是纯保险：正常时它只是躺着，出问题时顶住。
        self.buffer_s = float(buffer_s or 0.0)
        self._rate = None
        self._player = None
        self.first_audio_ms = None
        log(f"[嘴] {self.spk.name}")

    def __call__(self, chunk: np.ndarray, rate: int) -> None:
        use = self.replace_rate or rate
        if self._player is None or self._rate != use:
            if self._player is not None:
                try:
                    self._player.__exit__(None, None, None)
                except Exception:  # noqa: BLE001
                    pass
            self._player = None
            block = int(self.buffer_s * use) if self.buffer_s > 0 else None
            try:
                self._player = (self.spk.player(samplerate=use, channels=1, blocksize=block)
                                if block else self.spk.player(samplerate=use, channels=1))
            except Exception as e:  # noqa: BLE001
                # 有的驱动不接受自定义缓冲长度 —— 退回默认，别让一声都出不来
                log(f"[嘴] 缓冲 {self.buffer_s:.2f}s 没被接受（{type(e).__name__}），用默认")
                self._player = self.spk.player(samplerate=use, channels=1)
            self._rate = use
            self._player.__enter__()
        a = np.asarray(chunk, dtype="float32")
        if self.replace_rate and self.replace_rate != rate:
            from tts import resample
            a = resample(a, rate, self.replace_rate)
        self._player.play(a)

    def close(self) -> None:
        if self._player is not None:
            try:
                self._player.__exit__(None, None, None)
            except Exception:  # noqa: BLE001
                pass
            self._player = None


# ---------------------------------------------------------------- 命令行自测

def main() -> int:
    import argparse
    ap = argparse.ArgumentParser(description="不开网页、不开桌宠，直接试一次通话")
    ap.add_argument("--seconds", type=float, default=120.0)
    ap.add_argument("--source", default="mic", choices=["mic", "loopback"])
    ap.add_argument("--sink", default="speaker", choices=["speaker", "cable"])
    ap.add_argument("--device", default=None, help="录音端点名片段，不填用默认")
    ap.add_argument("--out-device", default=None, help="播放端点名片段，不填用默认")
    ap.add_argument("--tts", default="piper", choices=["piper", "cloud"])
    ap.add_argument("--model", default="small")
    ap.add_argument("--asr-device", default=None)
    args = ap.parse_args()

    for s in (sys.stdout, sys.stderr):
        try:
            s.reconfigure(encoding="utf-8", errors="replace")
        except Exception:  # noqa: BLE001
            pass

    os.makedirs(os.path.join(HERE, "..", "..", "state", "call"), exist_ok=True)

    t0 = time.time()
    from asr import AsrEngine
    log(f"[ASR] 加载 {args.model} …")
    asr = AsrEngine(model=args.model, device=args.asr_device)
    log(f"[ASR] {asr.describe()}")

    tts_engine = None
    if args.tts == "piper":
        import tts as ttsmod
        log("[TTS] 加载本地 piper …")
        tts_engine = ttsmod.PiperEngine()
        log(f"[TTS] piper {tts_engine.load_ms:.0f}ms · {tts_engine.rate}Hz")
    log(f"[就绪] 预热 {(time.time()-t0)*1000:.0f}ms —— 开始说话吧")

    sink = SpeakerSink("VB-Audio Virtual Cable" if args.sink == "cable" else args.out_device)
    eng = CallEngine(asr=asr, tts_backend=args.tts, tts_engine=tts_engine,
                     sink=sink, on_event=None)
    eng.start()
    src = MicSource(eng.feed, device_hint=args.device, loopback=(args.source == "loopback"))
    src.start()

    deadline = time.time() + args.seconds
    try:
        while time.time() < deadline:
            time.sleep(0.2)
    except KeyboardInterrupt:
        log("^C")
    finally:
        src.stop()
        eng.stop()
        sink.close()
    log(f"[结束] {len(eng.turns)} 轮")
    return 0


if __name__ == "__main__":
    sys.exit(main())
