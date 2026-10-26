# -*- coding: utf-8 -*-
"""GPT-SoVITS 常驻服务：模型只加载一次，通话进程按需向它要声音。

为什么不在通话进程里直接 import：
  v2 的四个权重（GPT / SoVITS / hubert / roberta）加起来要好几 GB 显存，
  加载一次二十秒起。而通话是「开窗 → 第一句话就出声」的事 ——
  每通电话重载一次，等于每通都先卡半分钟。
  所以模型住在一个常驻进程里，通话进程只连 127.0.0.1:<port>。

用法：
    python sovits_server.py                     # 起服务（默认 9880，cuda）
    python sovits_server.py --port 9880 --device cpu
    curl "http://127.0.0.1:9880/health"

接口（只实现我们用的那一小块，不追求兼容官方 api_v2）：
    GET /health                                   → {"ok": true, "load_ms": …}
    GET /tts?text=…&speed=1.0[&streaming=1]       → 裸 PCM：s16le / 单声道 / 采样率见 /health
    GET /tts?text=…&wav=1                         → 带 44 字节头的 wav（调试用）

⚠ 三个已知的坑（都是实测踩出来的）：
  ① **TTS_Config 的路径全是相对 cwd 的**（`GPT_SoVITS/configs/tts_infer.yaml`、
     权重路径也是）⇒ 加载前必须 `os.chdir(ROOT)`，否则它会在当前目录下现造一份 cpu 配置。
  ② sys.path 要同时有 ROOT 和 ROOT/GPT_SoVITS：`from tools.acceleration import …`
     找的是前者，`from AR.models… / from module.models…` 找的是后者。
  ③ 流式（streaming_mode=True）只在 v2/v1 这类非 vocoder 模型上成立；
     v3/v4 会自己回退成「分段返回」，那时首块会晚，别以为是坏了。
"""
from __future__ import annotations

import argparse
import io
import json
import os
import re
import struct
import sys
import threading
import time
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote, urlparse

for _s in (sys.stdout, sys.stderr):
    try:
        _s.reconfigure(encoding="utf-8", errors="replace")
    except Exception:  # noqa: BLE001
        pass

HERE = os.path.dirname(os.path.abspath(__file__))
def _find_root() -> str:
    """GPT-SoVITS 的根目录在哪儿？

    ① 环境变量 GSV_ROOT
    ② 几个常见位置（D 盘或 C 盘的 Tools 目录下，以及项目旁边）
    找不到就回一个默认值 —— 后面会打印得很清楚，不会悄悄跑错。
    """
    env = os.environ.get("GSV_ROOT")
    if env:
        return env
    for c in (r"D:\Tools\GPT-SoVITS", r"C:\Tools\GPT-SoVITS",
              os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..",
                           "GPT-SoVITS")):
        if os.path.isdir(c):
            return c
    return r"D:\Tools\GPT-SoVITS"


ROOT = _find_root()

# 参考音（零样本克隆全靠它）：路径 + 它**逐字**说了什么。
# prompt_text 必须和音频内容一致，差一个字音色就飘。
REF_AUDIO = os.path.join(ROOT, "ref", "ref-hy.wav")
PROMPT_TEXT = "嗯，我在呢。你说吧，今天过得怎么样？"

STATE = {"ready": False, "load_ms": 0, "err": None, "speak_reqs": 0, "last_first_chunk_ms": None,
         "device": None, "vram_mb": None}


def _prep_paths() -> None:
    for p in (ROOT, os.path.join(ROOT, "GPT_SoVITS")):
        if p not in sys.path:
            sys.path.insert(0, p)


def _patch_torchaudio_load() -> None:
    """★ 坑④（2026-10-26 实测）：torchaudio 2.11 把 `torchaudio.load` 转给了 torchcodec，
    而 torchcodec **没有 Windows 轮子**（uv 原话：`no wheels with a matching platform tag
    (e.g. win_amd64)`）⇒ 连参考音频都读不进来，报 `TorchCodec is required for
    load_with_torchcodec`。

    解法：把 `torchaudio.load` 换回 soundfile 读，返回 `(channels, samples)` 的形状不变。
    GPT-SoVITS 只有两处调它（TTS.py:119 读参考音、881 读另一个），都是属性调用，改得动。
    """
    import numpy as np
    import soundfile as sf
    import torch
    import torchaudio

    if getattr(torchaudio.load, "_gsv_patched", False):
        return

    def load(path, **kwargs):  # noqa: ANN001, ARG001
        data, sr = sf.read(str(path), dtype="float32", always_2d=True)
        if data.size == 0:
            return torch.zeros(1, 0, dtype=torch.float32), int(sr)
        return torch.from_numpy(np.ascontiguousarray(data.T)), int(sr)

    load._gsv_patched = True
    torchaudio.load = load
    print(f"[patch] torchaudio.load → soundfile（原实现是 {load.__name__} 前的 torchcodec 版）", flush=True)


class Engine:
    def __init__(self, device: str = "cuda", is_half: bool = True,
                 version: str = "v2", ref_audio: str = REF_AUDIO,
                 prompt_text: str = PROMPT_TEXT, warmup: bool = True):
        _prep_paths()
        # ★ 坑①：TTS_Config 里全是相对 cwd 的路径
        os.chdir(ROOT)
        import torch
        _patch_torchaudio_load()
        from TTS_infer_pack.TTS import TTS, TTS_Config

        if device == "cuda" and not torch.cuda.is_available():
            print("[warn] cuda 不可用，退回 cpu（会很慢）", flush=True)
            device, is_half = "cpu", False

        t0 = time.time()
        # ★★ 坑⑥（2026-10-26 19:1x 他说「全程在用核显、电脑卡爆」才挖出来）：
        #   `TTS_Config()` **无参时根本不读 `tts_infer.yaml`** —— 它把 `configs` 直接设成
        #   内置 `default_configs`（device=cpu / is_half=False），只在那份 yaml 不存在时才写一份出来。
        #   于是模型全部加载到 **CPU** 上：日志里照样打印 "on cuda"（那是我自己传的字符串），
        #   实际 `t2s_model` / `vits_model` / `bert` / `hubert` 每个参数都在 cpu、float32 ——
        #   实测 `torch.cuda.memory_allocated() == 0MB`，CPU 被推理榨干，整台机器卡。
        #   正确用法是**把 yaml 路径传进去**（官方 api_v2 就是这么干的），它会读 `custom` 段。
        yaml_path = os.path.join(ROOT, "GPT_SoVITS", "configs", "tts_infer.yaml")
        cfg = TTS_Config(yaml_path) if os.path.exists(yaml_path) else TTS_Config()
        # ★★ 坑⑥ 的后半段：`TTS_Config.__init__` 在第 406 行就把 `configs["device"]` **拷成了属性**
        #   `self.device` / `self.is_half`，而 `TTS()` 全程读的是**属性**，不是 dict。
        #   所以只改 `cfg.configs[...]` 一点用都没有（我第一次就是这么白改的：配置显示 cuda、
        #   模型还在 cpu）。必须改属性。
        #   顺带：`TTS_Config()` 无参那次会在末尾 `update_configs()` 把 cpu 写回 yaml 的 custom 段，
        #   所以 yaml 现在写的是 cpu —— 别指望它，以这里的显式赋值为准。
        for obj in (cfg, getattr(cfg, "configs", None)):
            if obj is None:
                continue
            try:
                if isinstance(obj, dict):
                    obj["device"] = device
                    obj["is_half"] = bool(is_half)
                obj.device = device
                obj.is_half = bool(is_half)
            except Exception:  # noqa: BLE001
                pass
        self.tts = TTS(cfg)
        # 落地校验：真的在 cuda 上吗？不在就明说，别让日志继续骗人。
        try:
            first_param = next(iter(self.tts.t2s_model.parameters()))
            real_dev = str(first_param.device)
            real_dtype = str(first_param.dtype)
        except Exception:  # noqa: BLE001
            real_dev, real_dtype = "?", "?"
        print(f"[device] 配置={cfg.configs.get('device')} is_half={cfg.configs.get('is_half')} "
              f"→ 模型实际在 {real_dev} / {real_dtype}", flush=True)
        if device == "cuda" and not real_dev.startswith("cuda"):
            print("[warn] ★ 模型没有落到 GPU 上！这会用 CPU 推理，整台机器会卡。", flush=True)
        self.rate = 32000
        self.load_ms = (time.time() - t0) * 1000
        self.ref_audio = ref_audio
        self.prompt_text = prompt_text
        STATE["load_ms"] = round(self.load_ms)

        if warmup:
            w0 = time.time()
            n = 0
            try:
                for _sr, chunk in self.tts.run(self._req("嗯")):
                    n += len(chunk)
                    break
            except Exception as e:  # noqa: BLE001
                print(f"[warn] 预热失败（不影响后面）：{type(e).__name__}: {e}", flush=True)
            print(f"[warmup] {round((time.time()-w0)*1000)}ms / {n} samples", flush=True)
        print(f"[ready] GPT-SoVITS {version} on {device}, 加载 {round(self.load_ms)}ms", flush=True)
        # ★ 记下**真的**落在哪张卡、占了多少显存 —— 2026-10-26 19:1x 他说「全程在用核显、电脑卡爆」，
        #   而 nvidia-smi 在 WDDM 模式下报的显存根本对不上（只有 1GB），所以让模型自己报。
        STATE["device"] = device
        try:
            if device == "cuda":
                STATE["vram_mb"] = round(torch.cuda.memory_reserved() / 2 ** 20)
                print(f"[ready] vram_reserved={STATE['vram_mb']}MB "
                      f"allocated={round(torch.cuda.memory_allocated() / 2 ** 20)}MB "
                      f"device_name={torch.cuda.get_device_name(0)}", flush=True)
        except Exception:  # noqa: BLE001
            pass
        STATE["ready"] = True

    def _req(self, text: str, speed: float = 1.0, streaming: bool = True) -> dict:
        return {
            "text": text,
            "text_lang": "zh",
            "ref_audio_path": self.ref_audio,
            "prompt_text": self.prompt_text,
            "prompt_lang": "zh",
            "top_k": 15,
            "top_p": 1.0,
            "temperature": 1.0,
            "text_split_method": "cut5",
            "batch_size": 1,
            "speed_factor": float(speed),
            "seed": -1,
            # 流式：按语义 token 切块往外吐，首块早、音质只略降
            "streaming_mode": bool(streaming),
            "return_fragment": False,
            "parallel_infer": not streaming,
            "split_bucket": False,
            "overlap_length": 2,
            "min_chunk_length": 16,
        }

    # ★ 切句：他 18:5x 说「稍微有一些卡顿」——
    #   原因是用流式模式**在句子内部**按语义 token 切块，块与块之间有接缝（听着像卡一下）。
    #   改成「按标点切成短句 → 每句整句合成 → 句间留一点静音」：
    #   句内没有接缝（不会卡），句间那点停顿本来就是人说话的样子。
    _HARD = "。！？；…\n"
    _SOFT = "，,、"
    _MAXLEN = 14          # 一句别超过 14 字，保证单句推理够快（首块 = 第一句的时间）
    _GAP_MS = 120         # 句间静音（老前提留，实际按标点分两档，见下）
    # ★ 2026-10-26 21:0x（他说「稍微好一点，但还是有卡顿」）：
    #   量下去才发现**卡的不是断流，是白**：模型每句自己带一截句首/句尾静音，
    #   我们又把整句首尾直接接起来，于是一个逗号处会静 **360 / 410 / 570 / 600 / 730ms**。
    #   听感上那就是「她说一半停住了，再接着往下说」—— 他说的卡顿大半是它。
    #   ⇒ 每句先掐掉首尾的静音（留住 20/30ms 当气息），再按标点给 70 / 140ms 的留白。
    _HARD_GAP = 140       # 。！？这类「真停」
    _SOFT_GAP = 70        # ，、这类「换气」

    @staticmethod
    def trim_silence(arr, rate: int, keep_head: float = 0.02, keep_tail: float = 0.03):
        import numpy as np
        if len(arr) == 0:
            return arr
        peak = float(np.max(np.abs(arr)))
        if peak <= 0.0:
            return arr
        thr = max(0.006, peak * 0.02)
        loud = np.where(np.abs(arr) > thr)[0]
        if not len(loud):
            return arr[:0]
        a = max(0, int(loud[0]) - int(keep_head * rate))
        b = min(len(arr), int(loud[-1]) + 1 + int(keep_tail * rate))
        return arr[a:b]

    @classmethod
    def split_clauses(cls, text: str) -> list[str]:
        """★ 2026-10-26 21:1x：**逗号也切**。

        他说「稍微好一点，但还是有卡顿」。量下去：模型自己在逗号处会停
        **360~730ms**（`trim_silence` 掐不掉 —— 那截白在句子中间，不在首尾）。
        ⇒ 那就别把逗号交给她：在逗号处切开、每段整句合成，段间由我们给 **70ms**。
          拍子就归我们管了，听感上是换气，不是断流。
        """
        segs, cur = [], ""
        for ch in text:
            cur += ch
            if ch in cls._HARD or ch in cls._SOFT:
                segs.append(cur)
                cur = ""
        if cur:
            segs.append(cur)
        out: list[str] = []
        for s in segs:
            s = s.strip()
            if not s:
                continue
            while len(s) > cls._MAXLEN:
                cut = max(s.rfind(c, 0, cls._MAXLEN) for c in cls._SOFT)
                if cut <= 0:
                    cut = cls._MAXLEN
                out.append(s[:cut + 1])
                s = s[cut + 1:].strip()
            if s:
                out.append(s)
        return out or [text]

    def stream(self, text: str, speed: float = 1.0, stats: dict | None = None,
               streaming: bool = False):
        """yield (rate, float32 mono)。

        `streaming=False`（默认）：**按小句切、每句整句合成** —— 句内无接缝，这是打电话该用的那条；
        `streaming=True`：句子内部也切块（首块更早，但接缝处会卡，只在极长句时才划算）。
        """
        import numpy as np
        t0 = time.time()
        first = None
        total = 0
        clauses = self.split_clauses(text)
        gap = None
        sr_now = int(self.rate or 32000)
        for idx, clause in enumerate(clauses):
            gen = self.tts.run(self._req(clause, speed=speed, streaming=streaming))
            for sr, chunk in gen:
                arr = _to_float(chunk)
                if len(arr) == 0:
                    continue
                sr_now = int(sr)
                arr = self.trim_silence(arr, sr_now)
                if len(arr) == 0:
                    continue
                if first is None:
                    first = (time.time() - t0) * 1000
                    STATE["last_first_chunk_ms"] = round(first)
                total += len(arr)
                yield sr_now, arr
            # 句间留一点静音（最后一句不留）；按标点决定长短
            if idx != len(clauses) - 1:
                gap_ms = self._HARD_GAP if clause[-1:] in self._HARD else self._SOFT_GAP
                n_gap = max(1, int(sr_now * 0.001 * gap_ms))
                if gap is None or len(gap) != n_gap:
                    gap = np.zeros(n_gap, dtype="float32")
                total += len(gap)
                yield sr_now, gap
        if stats is not None:
            stats["first_chunk_ms"] = round(first if first is not None else (time.time() - t0) * 1000)
            stats["total_ms"] = round((time.time() - t0) * 1000)
            stats["samples"] = int(total)
            stats["clauses"] = len(clauses)


ENGINE: Engine | None = None
SPEAK_LOCK = threading.Lock()


def _wav_header(rate: int, n_samples: int, channels: int = 1, width: int = 2) -> bytes:
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(channels)
        w.setsampwidth(width)
        w.setframerate(rate)
        w.setnframes(0)
    head = buf.getvalue()[:44]
    data_len = n_samples * width * channels
    return head[:4] + struct.pack("<I", 36 + data_len) + head[8:40] + struct.pack("<I", data_len)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # 少打点日志，别刷屏
        pass

    def _send_json(self, code: int, obj: dict) -> None:
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):  # noqa: N802
        u = urlparse(self.path)
        q = {k: v[0] for k, v in parse_qs(u.query).items()}
        if u.path == "/health":
            self._send_json(200, {"ok": STATE["ready"], "rate": getattr(ENGINE, "rate", 32000),
                                  **{k: v for k, v in STATE.items() if k != "ready"}})
            return
        if u.path != "/tts":
            self._send_json(404, {"ok": False, "err": "not found"})
            return
        text = (q.get("text") or "").strip()
        if not text:
            self._send_json(400, {"ok": False, "err": "text required"})
            return
        if ENGINE is None or not STATE["ready"]:
            self._send_json(503, {"ok": False, "err": "model not ready", "detail": STATE["err"]})
            return
        speed = float(q.get("speed") or 1.0)
        want_wav = q.get("wav") in ("1", "true", "yes")
        streaming = q.get("stream", "1") not in ("0", "false", "no")
        stats: dict = {}
        try:
            with SPEAK_LOCK:
                gen = ENGINE.stream(text, speed=speed, stats=stats, streaming=streaming)
                first = next(gen, None)
                if first is None:
                    self._send_json(500, {"ok": False, "err": "no audio"})
                    return
                rate, _arr = first
                self.send_response(200)
                if want_wav:
                    # 不知道总长，先给一个「0 长度」的头，多数播放器能容忍（调试够用）
                    self.send_header("Content-Type", "audio/wav")
                    self.send_header("Transfer-Encoding", "chunked")
                    self.end_headers()
                    self._chunk(_wav_header(rate, 0))
                else:
                    self.send_header("Content-Type", "audio/pcm")
                    self.send_header("X-Sample-Rate", str(rate))
                    self.send_header("Transfer-Encoding", "chunked")
                    self.end_headers()
                self._chunk(_pcm16(_arr))
                for _sr, arr in gen:
                    self._chunk(_pcm16(arr))
                self.wfile.write(b"0\r\n\r\n")
                STATE["speak_reqs"] = int(STATE["speak_reqs"]) + 1
        except BrokenPipeError:
            return
        except Exception as e:  # noqa: BLE001
            import traceback
            traceback.print_exc()
            try:
                self._send_json(500, {"ok": False, "err": f"{type(e).__name__}: {e}"})
            except Exception:  # noqa: BLE001
                pass

    def _chunk(self, data: bytes) -> None:
        if not data:
            return
        self.wfile.write(("%X\r\n" % len(data)).encode("ascii"))
        self.wfile.write(data)
        self.wfile.write(b"\r\n")
        try:
            self.wfile.flush()
        except Exception:  # noqa: BLE001
            pass


def _to_float(chunk):
    """★ 坑⑤（2026-10-26，他说「很炸的那种模糊」才查出来）：GPT-SoVITS 的 `run()`
    吐出来的是 **int16**（-32768..32767），不是 -1..1 的 float。
    我一开始统统 `astype("float32")` 当成波形值 ⇒ 任何非零样本都 >1
    ⇒ 后面 clip 到 ±1 再乘 32767 ⇒ **整段变成满幅方波**：
    人声轮廓还在（所以他还听得出是人），但每一帧都贴在满幅上互相砸 —— 就是「炸」。
    实测判据：RMS 0.91（正常语音 0.1~0.25）。
    """
    import numpy as np
    arr = np.asarray(chunk)
    if arr.dtype == np.int16:
        return (arr.astype("float32") / 32768.0).ravel()
    if arr.dtype.kind in "iu":            # 万一哪天变成 int32
        return (arr.astype("float32") / 2147483648.0).ravel()
    return arr.astype("float32").ravel()


def _pcm16(arr) -> bytes:
    import numpy as np
    x = np.asarray(arr, dtype="float32").ravel()
    return (np.clip(x, -1.0, 1.0) * 32767.0).astype("<i2").tobytes()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=9880)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--device", default="cuda")
    ap.add_argument("--half", dest="half", action="store_true", default=True)
    ap.add_argument("--no-half", dest="half", action="store_false")
    ap.add_argument("--version", default="v2")
    ap.add_argument("--ref", default=REF_AUDIO)
    ap.add_argument("--prompt", default=PROMPT_TEXT)
    ap.add_argument("--prompt-file", default=None,
                    help="从 UTF-8 文件读参考文本（★ 别走命令行：这台机器 ACP=936，"
                         "命令行里的中文会被搞坏）")
    ap.add_argument("--no-warmup", action="store_true")
    args = ap.parse_args()

    global ENGINE
    prompt = args.prompt
    if args.prompt_file:
        with open(args.prompt_file, "r", encoding="utf-8") as f:
            prompt = f.read().strip()
    print(f"[boot] ROOT={ROOT} device={args.device} ref={args.ref}", flush=True)
    print(f"[boot] prompt_len={len(prompt)}", flush=True)
    if not os.path.exists(args.ref):
        print(f"[fatal] 参考音不存在：{args.ref}", flush=True)
        return 2
    try:
        ENGINE = Engine(device=args.device, is_half=args.half, version=args.version,
                        ref_audio=args.ref, prompt_text=prompt,
                        warmup=not args.no_warmup)
    except Exception as e:  # noqa: BLE001
        import traceback
        traceback.print_exc()
        STATE["err"] = f"{type(e).__name__}: {e}"
        print(f"[fatal] 模型加载失败：{STATE['err']}", flush=True)
        return 3

    srv = ThreadingHTTPServer((args.host, args.port), Handler)
    srv.daemon_threads = True
    print(f"[listen] http://{args.host}:{args.port}  rate={ENGINE.rate}", flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
