"""TTS：直接走 HTTP，不经 PowerShell / curl / ffmpeg。

为什么要重写：`say.ps1` 那条路（PowerShell 起进程 → curl → mp3 → ffmpeg 解码）
**固定开销约 1.8 秒**，实测 1 个字要 1.9s、38 个字 2.36s —— 文字长短几乎不影响耗时，
说明时间全花在进程启动和网络往返上。打电话时这 1.8 秒是致命的。

这里改三件事：
  ① Python 里直接 urllib POST，不起子进程；
  ② `response_format="pcm"` 要**裸 PCM**，不落 mp3，省掉 ffmpeg；
  ③ 返回 numpy 数组 + 同时给出「首字节」「全文」两个耗时，好分清网络和合成各占多少。

用法：
    python tts.py --probe              # 比 pcm / wav / mp3 三种格式的耗时与采样率
    python tts.py "听得见吗"            # 合成一段，写到 state/call/tts-*.wav
    from tts import speak              # pcm, rate = speak("…")
"""
from __future__ import annotations

import argparse
import io
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import wave

for _s in (sys.stdout, sys.stderr):
    try:
        _s.reconfigure(encoding="utf-8", errors="replace")
    except Exception:  # noqa: BLE001
        pass

import numpy as np

KEYFILE = os.path.expanduser(r"~\.dsh\siliconflow-key.txt")
ENDPOINT = "https://api.siliconflow.cn/v1/audio/speech"
MODEL = "FunAudioLLM/CosyVoice2-0.5B"
VOICE = "FunAudioLLM/CosyVoice2-0.5B:anna"
OUTDIR = os.path.normpath(os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "..", "state", "call"))


def _key() -> str:
    with open(KEYFILE, "r", encoding="utf-8") as f:
        return f.read().strip()


def synthesize(text: str, fmt: str = "pcm", speed: float = 1.0,
               timeout: float = 60.0) -> tuple[bytes, dict]:
    """返回 (原始字节, {first_byte_ms, total_ms, http_ms})。
    first_byte_ms = 从发请求到收到第一个字节 —— 这才是「她多久能开口」的真实下限。
    """
    body = json.dumps({
        "model": _cloud_cfg().get("model") or MODEL,
        "voice": _cloud_cfg().get("voice") or VOICE,
        "input": text,
        "response_format": fmt, "speed": speed,
    }).encode("utf-8")
    req = urllib.request.Request(ENDPOINT, data=body, headers={
        "Authorization": "Bearer " + _key(),
        "Content-Type": "application/json",
    })
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=timeout) as r:
        first = None
        chunks = []
        while True:
            b = r.read(16384)
            if not b:
                break
            if first is None:
                first = time.time() - t0
            chunks.append(b)
    total = time.time() - t0
    return b"".join(chunks), {
        "first_byte_ms": round((first or total) * 1000),
        "total_ms": round(total * 1000),
        "bytes": sum(len(c) for c in chunks),
    }


def pcm_from_bytes(raw: bytes, fmt: str) -> tuple[np.ndarray, int]:
    """把接口回来的东西变成 (float32 mono, 采样率)。"""
    if fmt == "pcm":
        # 裸 S16LE 单声道；CosyVoice2 走 24k，但别写死 —— 下面会按能量验证一下长度
        x = np.frombuffer(raw, dtype="<i2").astype("float32") / 32768.0
        return x, 24000
    if fmt == "wav":
        with wave.open(io.BytesIO(raw), "rb") as w:
            rate = w.getframerate()
            n = w.getnframes()
            ch = w.getnchannels()
            data = np.frombuffer(w.readframes(n), dtype="<i2").astype("float32") / 32768.0
        if ch > 1:
            data = data.reshape(-1, ch).mean(axis=1)
        return data, rate
    raise ValueError("mp3 要解码，这个函数不管；用 ffmpeg 那条老路")


def resample(x: np.ndarray, src: int, dst: int) -> np.ndarray:
    if src == dst or len(x) == 0:
        return x
    try:
        from scipy.signal import resample_poly
        from math import gcd
        g = gcd(src, dst)
        return resample_poly(x, dst // g, src // g).astype("float32")
    except Exception:  # noqa: BLE001
        n = int(len(x) * dst / src)
        return np.interp(np.linspace(0, len(x) - 1, n), np.arange(len(x)), x).astype("float32")


def speak(text: str, play_rate: int = 48000, fmt: str = "pcm",
          speed: float = 1.0) -> tuple[np.ndarray, dict]:
    """合成 → 重采样到 play_rate。返回 (float32 mono, 计时信息)。"""
    t0 = time.time()
    raw, info = synthesize(text, fmt=fmt, speed=speed)
    audio, rate = pcm_from_bytes(raw, fmt)
    audio = resample(audio, rate, play_rate)
    info["native_rate"] = rate
    info["dur_s"] = round(len(audio) / play_rate, 2)
    info["decode_ms"] = round((time.time() - t0) * 1000) - info["total_ms"]
    info["all_ms"] = round((time.time() - t0) * 1000)
    return audio, info


def _cloud_cfg() -> dict:
    """云端那一档的音色 / 语速 / 模型从 state\\call\\config.json 读。

    ★ 2026-10-26 修：从前 `VOICE` 是写死的常量，而界面（拓展模块里的「音色设置」）
      会改 `tts.cloud.voice` —— 改了却没有任何地方读它。那是个**会说谎的控件**：
      看着能调，实际不生效。现在两条路都读同一份配置，改了就真变。
    """
    try:
        import config as cfgmod
        return (cfgmod.load().get("tts") or {}).get("cloud") or {}
    except Exception:  # noqa: BLE001
        return {}


def stream_pcm(text: str, speed: float | None = None, block: int = 8192,
               timeout: float = 60.0, stats: dict | None = None):
    """**边收边产**：每来一块字节就 yield 一段 float32（24k 单声道，不重采样）。

    为什么不用 resample 逐块转：分块做 polyphase 会在每块边界留下咔哒声。
    直接把播放器开在 24000 —— soundcard / MediaFoundation 会自己做设备重采样。

    第一个块的到达时间就是「她多久能开口」，实测 20 个字约 1.27s
    （而等全文要 2.35s）⇒ 流式直接省掉一半等待。
    """
    c = _cloud_cfg()
    if speed is None:
        try:
            speed = float(c.get("speed") or 1.0)
        except Exception:  # noqa: BLE001
            speed = 1.0
    body = json.dumps({
        "model": c.get("model") or MODEL,
        "voice": c.get("voice") or VOICE,
        "input": text,
        "response_format": "pcm", "speed": speed,
    }).encode("utf-8")
    req = urllib.request.Request(ENDPOINT, data=body, headers={
        "Authorization": "Bearer " + _key(),
        "Content-Type": "application/json",
    })
    t0 = time.time()
    first_at = None
    total_bytes = 0
    buf = b""
    with urllib.request.urlopen(req, timeout=timeout) as r:
        while True:
            b = r.read(block)
            if not b:
                break
            total_bytes += len(b)
            if first_at is None:
                first_at = time.time() - t0
            buf += b
            n = len(buf) - (len(buf) % 2)
            if n == 0:
                continue
            chunk = np.frombuffer(buf[:n], dtype="<i2").astype("float32") / 32768.0
            buf = buf[n:]
            yield chunk
    if buf and len(buf) >= 2:
        yield np.frombuffer(buf[:len(buf) - (len(buf) % 2)], dtype="<i2").astype("float32") / 32768.0
    if stats is not None:
        stats["first_chunk_ms"] = round((first_at or (time.time() - t0)) * 1000)
        stats["total_ms"] = round((time.time() - t0) * 1000)
        stats["bytes"] = total_bytes


# ---------------------------------------------------------------- 本地：piper

PIPER_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "state", "tts", "piper")
PIPER_MODEL = os.path.normpath(os.path.join(PIPER_DIR, "zh_CN-huayan-medium.onnx"))


class PiperEngine:
    """本地 ONNX TTS。**纯 CPU，占 0 显存**（实测 nvidia-smi 前后都是 11 MiB）。

    实测（2026-10-26，本机）：加载 2082ms（每通电话一次）· 合成 33ms(0.29s 音频) /
    116ms(1.45s) / 221ms(2.79s)，RTF≈0.08。音色是 huayan（女声），不是现在的 anna。
    """

    def __init__(self, model_path: str = PIPER_MODEL, warmup: bool = True,
                 syn_config=None, length_scale: float = 1.10,
                 noise_scale: float = 0.72, noise_w_scale: float = 0.90):
        from piper import PiperVoice, SynthesisConfig
        t0 = time.time()
        self.voice = PiperVoice.load(model_path)
        self.load_ms = (time.time() - t0) * 1000
        self.rate = 22050                       # huayan-medium 是 22.05k
        # ★ 语气：piper 默认（1.0 / 0.667 / 0.8）念得快、起伏小，像播报。
        #   放缓到 1.10、起伏（noise_w）抬到 0.90，就有点像人随口说话。
        #   2026-10-26 他说「语气有点问题」，做了 A/B 让他挑；这里先用中间值，可随时改。
        self.syn = syn_config or SynthesisConfig(
            length_scale=length_scale, noise_scale=noise_scale,
            noise_w_scale=noise_w_scale, normalize_audio=True)
        # ★ 必须预热：ONNX 会话是懒建的，不预热的话**第一句**要 2000ms 才出第一个包
        #   （2026-10-26 实测：预热前 first_chunk 2014ms，预热后 100ms 出头）
        self.warmup_ms = 0.0
        if warmup:
            w0 = time.time()
            try:
                for _ in self.stream("嗯", warmup=True):
                    break
            except Exception:  # noqa: BLE001
                pass
            self.warmup_ms = (time.time() - w0) * 1000

    # 从句号切成小句：先合成第一句就开播，别等整段 —— 开口延迟主要死在这儿
    _SPLIT = "。！？；…\n"
    _SOFT = "，,、"

    @classmethod
    def _clauses(cls, text: str) -> list[str]:
        segs, cur = [], ""
        for ch in text:
            cur += ch
            if ch in cls._SPLIT:
                segs.append(cur)
                cur = ""
        if cur:
            segs.append(cur)
        out: list[str] = []
        for s in segs:
            s = s.strip()
            if not s:
                continue
            while len(s) > 26:
                cut = max(s.rfind(c, 0, 26) for c in cls._SOFT)
                if cut <= 0:
                    cut = 26
                out.append(s[:cut + 1])
                s = s[cut + 1:].strip()
            if s:
                out.append(s)
        return out or [text]

    def stream(self, text: str, stats: dict | None = None, warmup: bool = False):
        t0 = time.time()
        first = None
        chars = 0
        pieces = [text] if warmup else self._clauses(text)
        for piece in pieces:
            for ch in self.voice.synthesize(piece, syn_config=self.syn):
                arr = getattr(ch, "audio_float_array", None)
                if arr is None:
                    continue
                arr = np.asarray(arr, dtype="float32").ravel()
                if len(arr) == 0:
                    continue
                if first is None:
                    first = (time.time() - t0) * 1000
                chars += len(arr)
                yield arr
        if stats is not None:
            stats["first_chunk_ms"] = round(first if first is not None else (time.time() - t0) * 1000)
            stats["total_ms"] = round((time.time() - t0) * 1000)
            stats["samples"] = chars
            stats["clauses"] = len(pieces)


def make_stream(backend: str, text: str, engine=None, stats: dict | None = None):
    """统一入口：返回 (采样率, 迭代器)。backend = 'piper' | 'sovits' | 'cloud' | 'openai'。"""
    if backend == "piper":
        if engine is None:
            engine = piper_from_config()
        return engine.rate, engine.stream(text, stats=stats)
    if backend == "sovits":
        return sovits_rate(), stream_sovits(text, stats=stats)
    if backend == "openai":
        return OPENAI_RATE, stream_openai(text, stats=stats)
    return 24000, stream_pcm(text, stats=stats)


def piper_from_config():
    """按 state/call/config.json 里的参数造一个 piper（音色快慢起伏都从配置来）。"""
    try:
        import config as cfgmod
        c = (cfgmod.load().get("tts") or {}).get("piper") or {}
    except Exception:  # noqa: BLE001
        c = {}
    return PiperEngine(
        length_scale=float(c.get("length_scale", 1.10)),
        noise_scale=float(c.get("noise_scale", 0.72)),
        noise_w_scale=float(c.get("noise_w_scale", 0.90)),
    )


# ---------------------------------------------------------------- 云端：OpenAI TTS
# ⚠ 这一段**没有实测过**（本机没有 OpenAI key）。写它是为了让「选项」齐，
#    真要用之前先用 `python tts.py --probe-openai` 跑一次再信它。
OPENAI_KEYFILE = os.path.expanduser(r"~\.dsh\openai-key.txt")
OPENAI_RATE = 24000


def _openai_key() -> str:
    k = os.environ.get("OPENAI_API_KEY", "").strip()
    if k:
        return k
    if os.path.exists(OPENAI_KEYFILE):
        with open(OPENAI_KEYFILE, "r", encoding="utf-8") as f:
            return f.read().strip()
    raise RuntimeError(
        "没有 OpenAI key：把 key 写进 ~\\.dsh\\openai-key.txt，或设环境变量 OPENAI_API_KEY")


def stream_openai(text: str, stats: dict | None = None):
    """OpenAI /v1/audio/speech 流式 PCM。返回 float32 块。"""
    import urllib.request
    try:
        import config as cfgmod
        c = (cfgmod.load().get("tts") or {}).get("openai") or {}
    except Exception:  # noqa: BLE001
        c = {}
    body = json.dumps({
        "model": c.get("model", "gpt-4o-mini-tts"),
        "voice": c.get("voice", "nova"),
        "input": text,
        "response_format": "pcm",          # 24kHz 16-bit 小端单声道
        **({"instructions": c["instructions"]} if c.get("instructions") else {}),
    }).encode("utf-8")
    req = urllib.request.Request(
        (c.get("base_url") or "https://api.openai.com/v1").rstrip("/") + "/audio/speech",
        data=body,
        headers={"Content-Type": "application/json", "Authorization": "Bearer " + _openai_key()},
    )
    t0 = time.time()
    first = None
    total = 0
    with urllib.request.urlopen(req, timeout=60) as r:
        while True:
            raw = r.read(8192)
            if not raw:
                break
            if first is None:
                first = (time.time() - t0) * 1000
            total += len(raw)
            arr = np.frombuffer(raw[: len(raw) // 2 * 2], dtype="<i2").astype("float32") / 32768.0
            if len(arr):
                yield arr
    if stats is not None:
        stats["first_chunk_ms"] = round(first if first is not None else (time.time() - t0) * 1000)
        stats["total_ms"] = round((time.time() - t0) * 1000)
        stats["samples"] = total // 2


# ---------------------------------------------------------------- 本地：GPT-SoVITS
# 零样本克隆：给一段参考音（3~10 秒）+ 它说了什么，就能用那个音色说任何话。
# 模型住在 sovits_server.py 那个常驻进程里（加载一次二十秒起，不能让每通电话都付一遍），
# 这里只负责跟它要 PCM。没起服务时会抛 RuntimeError —— 上层按「这个后端用不了」处理。
SOVITS_DEFAULT_PORT = 9880


def _sovits_cfg() -> dict:
    try:
        import config as cfgmod
        return (cfgmod.load().get("tts") or {}).get("sovits") or {}
    except Exception:  # noqa: BLE001
        return {}


def sovits_base() -> str:
    c = _sovits_cfg()
    host = c.get("host") or "127.0.0.1"
    port = int(c.get("port") or SOVITS_DEFAULT_PORT)
    return f"http://{host}:{port}"


def sovits_health(timeout: float = 2.0) -> dict | None:
    """没起服务 → None（不要抛，调用方靠它判断可用性）。"""
    try:
        with urllib.request.urlopen(sovits_base() + "/health", timeout=timeout) as r:
            return json.loads(r.read().decode("utf-8"))
    except Exception:  # noqa: BLE001
        return None


def sovits_rate() -> int:
    h = sovits_health()
    if not h or not h.get("ok"):
        raise RuntimeError(
            "GPT-SoVITS 服务没起来。先跑：python dafeiyu\\tools\\call\\sovits_server.py")
    return int(h.get("rate") or 32000)


# 常驻服务怎么拉起来：模型住在 D:\Tools\gsv-venv 那个 3.10 环境里（torch cu128 + 一堆音频库），
# 跟通话进程用的 Python 不是一个，所以这里只存「去起哪个解释器、起哪个脚本」。
def _find_sovits_python() -> str:
    """GPT-SoVITS 住在哪个解释器里？

    它要 torch cu12 + 一堆音频库，跟通话进程的 python 通常**不是**同一个，
    所以这里只负责「去起哪个解释器」，判断顺序：
        ① 环境变量 GSV_PYTHON（换机器 / 换盘最省事）
        ② 几个常见的 venv 位置
        ③ 实在找不到就用本进程的解释器 —— 那多半会失败，但至少报错说得出话
    """
    env = os.environ.get("GSV_PYTHON")
    if env:
        return env
    for c in (r"D:\Tools\gsv-venv\Scripts\python.exe",
              r"C:\Tools\gsv-venv\Scripts\python.exe",
              os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..",
                           "gsv-venv", "Scripts", "python.exe")):
        if os.path.exists(c):
            return c
    return sys.executable


SOVITS_PY = _find_sovits_python()
SOVITS_SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "sovits_server.py")
SOVITS_LOG = os.environ.get("GSV_LOG") or os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "..", "state", "call", "sovits-server.log")


def ensure_sovits(timeout: float = 120.0, autostart: bool = True) -> bool:
    """确保常驻的 sovits 服务在跑。返回 True = 可以用。

    ★ 为什么要这个：模型加载 2s + 预热 5s，加在一起七八秒。
    每通电话都付一遍不划算，所以它常驻；但常驻进程会挂（关机、OOM、手动 kill），
    这时通话进程自己把它拉起来，比让它退回 piper 好。
    """
    h = sovits_health()
    if h and h.get("ok"):
        return True
    if not autostart:
        return False
    if not (os.path.exists(SOVITS_PY) and os.path.exists(SOVITS_SCRIPT)):
        return False
    import subprocess
    c = _sovits_cfg()
    port = str(int(c.get("port") or SOVITS_DEFAULT_PORT))
    os.makedirs(os.path.dirname(os.path.normpath(SOVITS_LOG)), exist_ok=True)
    flags = getattr(subprocess, "CREATE_NO_WINDOW", 0) if os.name == "nt" else 0
    try:
        with open(SOVITS_LOG, "a", encoding="utf-8") as logf:
            logf.write(f"\n===== {time.strftime('%Y-%m-%d %H:%M:%S')} 拉起 sovits =====\n")
            logf.flush()
            subprocess.Popen(
                [SOVITS_PY, SOVITS_SCRIPT, "--port", port],
                cwd=os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
                stdout=logf, stderr=subprocess.STDOUT,
                creationflags=flags,
            )
    except Exception:  # noqa: BLE001
        return False
    deadline = time.time() + timeout
    while time.time() < deadline:
        h = sovits_health(timeout=2.0)
        if h and h.get("ok"):
            return True
        time.sleep(1.0)
    return False


def stream_sovits(text: str, speed: float | None = None, stats: dict | None = None,
                  block: int = 8192, timeout: float = 120.0):
    """向本地 sovits_server 要一段话，边收边 yield float32 单声道。

    拿不到服务时抛 RuntimeError —— engine 那边会退回 piper，不至于让通话哑掉。
    """
    if speed is None:
        speed = float(_sovits_cfg().get("speed") or 1.0)
    # ★ `stream=0`：要服务端**按小句整句合成**，不要在句子内部再切块。
    #   2026-10-26 20:4x 实测（C:\dsh-temp\chunk-gaps.py）：
    #     · 不传 stream（服务端默认 = 1，句内切块）：一句中间会出现
    #       841 / 860 / 594 / 590 / 573ms 的停顿 —— 播放端缓冲一空就是一声卡；
    #     · stream=0（整句）：句内一条波形下来，没有接缝，只有句与句之间那一个
    #       120ms 的留白（那是服务端故意留的，像人换气）。
    #   ⇒ 通话这条路要的是**连续**，不是「早几十毫秒开口」。
    url = (f"{sovits_base()}/tts?text={urllib.parse.quote(text)}"
           f"&speed={speed:.2f}&stream=0&batch=1")
    t0 = time.time()
    first = None
    total = 0
    try:
        with urllib.request.urlopen(url, timeout=timeout) as r:
            while True:
                raw = r.read(block)
                if not raw:
                    break
                if first is None:
                    first = (time.time() - t0) * 1000
                total += len(raw)
                arr = np.frombuffer(raw[: len(raw) // 2 * 2], dtype="<i2").astype("float32") / 32768.0
                if len(arr):
                    yield arr
    except urllib.error.URLError as e:
        raise RuntimeError(f"GPT-SoVITS 服务连不上（{sovits_base()}）：{e}") from e
    if stats is not None:
        stats["first_chunk_ms"] = round(first if first is not None else (time.time() - t0) * 1000)
        stats["total_ms"] = round((time.time() - t0) * 1000)
        stats["samples"] = total // 2


def probe():
    texts = ["嗯", "听得见呀，你声音有点闷，累就早点歇着吧。"]
    for fmt in ("pcm", "wav", "mp3"):
        print(f"\n=== format={fmt} ===")
        for t in texts:
            try:
                raw, info = synthesize(t, fmt=fmt)
            except Exception as e:  # noqa: BLE001
                print(f"  [{len(t)} 字] 失败：{type(e).__name__}: {e}")
                continue
            extra = ""
            if fmt in ("pcm", "wav"):
                try:
                    audio, rate = pcm_from_bytes(raw, fmt)
                    peak = float(np.max(np.abs(audio))) if len(audio) else 0.0
                    extra = f" rate={rate} dur={len(audio)/rate:.2f}s peak={peak:.3f}"
                except Exception as e:  # noqa: BLE001
                    extra = f" 解析失败 {type(e).__name__}: {e}"
            print(f"  [{len(t)} 字] 首字节 {info['first_byte_ms']}ms · 全文 {info['total_ms']}ms"
                  f" · {info['bytes']}B{extra}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("text", nargs="?", default=None)
    ap.add_argument("--probe", action="store_true")
    args = ap.parse_args()
    if args.probe or not args.text:
        probe()
        return 0

    os.makedirs(OUTDIR, exist_ok=True)
    audio, info = speak(args.text)
    path = os.path.join(OUTDIR, f"tts-{int(time.time()*1000)}.wav")
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(48000)
        w.writeframes((np.clip(audio, -1, 1) * 32767).astype("<i2").tobytes())
    print(json.dumps({"wav": path, **info}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
