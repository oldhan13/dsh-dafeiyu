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

SYSTEM = (
    "你正在和主人打电话。声音传过去，所以只说口语。\n"
    "每次回话不超过 25 个字，一到两句，可以带一点语气词。\n"
    "不要列表、不要加粗、不要括号里的旁白、不要念表情符号。\n"
    "听不清就直说听不清，不要瞎猜。"
)

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


def brain_say(history: list[dict], system: str = SYSTEM,
              model: str = "deepseek-chat", timeout: float = 20.0) -> tuple[str, float]:
    import urllib.request

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
                 sink=None, on_event=None, system: str = SYSTEM,
                 model: str = "deepseek-chat", seed: list[dict] | None = None,
                 verbose: bool = True):
        # 不指定就按 state/call/config.json 里选的（界面切的就是它）
        if not tts_backend:
            try:
                import config as cfgmod
                tts_backend = cfgmod.backend()
            except Exception:  # noqa: BLE001
                tts_backend = "piper"
        self.asr = asr
        self.tts_backend = tts_backend
        self.tts_engine = tts_engine
        self.sink = sink
        self.on_event = on_event
        self.system = system
        self.model = model
        self.verbose = verbose

        self.history: list[dict] = list(seed or [])
        self.state = "idle"
        self.level = 0.0

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
            if self._speech > 0 and (time.monotonic() - self._last_frame) > (SILENCE_END + 0.25):
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
            if self._silence >= SILENCE_END:
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
        reply, brain_ms = brain_say(self.history[-HISTORY_MAX:], self.system, self.model)
        turn["brain_ms"] = round(brain_ms)
        turn["reply"] = reply
        self.history.append({"role": "assistant", "content": reply})
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
        tts_rate, it = ttsmod.make_stream(self.tts_backend, reply,
                                          engine=self.tts_engine, stats=stats)
        self._speaking.set()
        self._set_state("speaking")
        self.emit("say_start", rate=tts_rate)
        first_ms = None
        played_samples = 0
        try:
            for ch in it:
                if self._abort.is_set() or self._stop.is_set():
                    break
                if self.sink is not None:
                    self.sink(ch, tts_rate)
                if first_ms is None:
                    first_ms = (time.time() - t_tts) * 1000
                played_samples += len(ch)
        finally:
            self._speaking.clear()
            self.emit("say_end", interrupted=self._abort.is_set())

        tts_ms = (time.time() - t_tts) * 1000
        turn.update({
            "tts_backend": self.tts_backend,
            "tts_ms": round(tts_ms),
            "tts_first_audio_ms": round(first_ms or 0),
            "played_s": round(played_samples / max(1, tts_rate), 2),
            "interrupted": self._abort.is_set(),
            "first_sound_ms": round(asr_ms + brain_ms + (first_ms or 0)),
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

    def __init__(self, device_hint: str | None = None, replace_rate: int | None = None):
        import soundcard as sc
        if device_hint:
            hint = device_hint.lower()
            self.spk = next((s for s in sc.all_speakers() if hint in s.name.lower()), None)
            if self.spk is None:
                raise RuntimeError(f"找不到播放端点（含 {device_hint}）")
        else:
            self.spk = sc.default_speaker()
        self.replace_rate = replace_rate
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
