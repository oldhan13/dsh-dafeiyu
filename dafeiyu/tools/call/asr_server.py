# -*- coding: utf-8 -*-
"""常驻的耳朵：whisper 只加载一次，通话进程按需向它要文字。

为什么要有它（2026-10-26 19:3x 他说的）：
    他原话「没有办法让这些资源在5080上运行吗，它完全是空闲的啊」。
    量出来：5080 只用了 **2597 / 16303 MiB** —— 卡根本是空的。
    所以这里的问题从来不是「省显存」，而是 **「每通电话重新往卡上装一遍模型」**：
    ASR 实测每次加载+warmup **2.62s**，而它装上去以后本该一直待在那儿。
    ⇒ 耳朵也做成常驻，跟嘴（sovits_server）一个待遇。

跟 sovits_server 的差别：ASR 是**有问才有答**的短请求，不需要流式；
所以接口就两个，收一整段 PCM，回一整句文字。

接口：
    GET  /health   → {"ok":true,"model":"small","device":"cuda","compute":"float16","load_ms":…,"reqs":…}
    POST /asr      → body: s16le / 单声道 / 16000Hz 裸 PCM
                     回: {"ok":true,"text":"…","ms":123.4}

用法：
    python asr_server.py                  # 默认 127.0.0.1:9890
    python asr_server.py --model small --device cuda
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

for _s in (sys.stdout, sys.stderr):
    try:
        _s.reconfigure(encoding="utf-8", errors="replace")
    except Exception:  # noqa: BLE001
        pass

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

STATE = {"ready": False, "load_ms": 0, "device": None, "compute": None,
         # ★ model 必须报出来（2026-10-26 加）：它是常驻进程，配置改了要重启才生效 ——
         #   界面得能看见「现在耳朵里到底是哪一档」，否则「我明明选了 medium」没法核对。
         "model": None,
         "reqs": 0, "last_ms": None, "err": None}

ENGINE = None
LOCK = threading.Lock()          # 一次只转写一句：模型不是线程安全的，也不需要并行


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):   # 别刷屏
        pass

    def _json(self, code: int, obj: dict) -> None:
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):  # noqa: N802
        path = (self.path or "/").split("?")[0]
        if path == "/health":
            self._json(200, {"ok": STATE["ready"], **{k: v for k, v in STATE.items()
                                                      if k != "ready"}})
            return
        if path == "/quit":
            self._json(200, {"ok": True, "bye": True})
            threading.Thread(target=lambda: (time.sleep(0.2), os._exit(0)),
                             daemon=True).start()
            return
        self._json(404, {"ok": False, "err": "not found"})

    def do_POST(self):  # noqa: N802
        path = (self.path or "/").split("?")[0]
        if path != "/asr":
            self._json(404, {"ok": False, "err": "not found"})
            return
        try:
            n = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            n = 0
        if n <= 0:
            self._json(400, {"ok": False, "err": "empty body"})
            return
        raw = self.rfile.read(n)
        if ENGINE is None or not STATE["ready"]:
            self._json(503, {"ok": False, "err": "model not ready", "detail": STATE["err"]})
            return
        import numpy as np
        audio = np.frombuffer(raw[: len(raw) // 2 * 2], dtype="<i2").astype("float32") / 32768.0
        try:
            with LOCK:
                t0 = time.time()
                text = ENGINE.transcribe(audio)
                ms = (time.time() - t0) * 1000.0
                STATE["reqs"] = int(STATE["reqs"]) + 1
                STATE["last_ms"] = round(ms, 1)
            self._json(200, {"ok": True, "text": text, "ms": round(ms, 1)})
        except Exception as e:  # noqa: BLE001
            import traceback
            traceback.print_exc()
            self._json(500, {"ok": False, "err": f"{type(e).__name__}: {e}"})


def main() -> int:
    global ENGINE
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=9890)
    ap.add_argument("--model", default="small")
    ap.add_argument("--device", default=None, help="不填就 cuda，不行退 cpu")
    ap.add_argument("--compute", default=None)
    args = ap.parse_args()

    from asr import AsrEngine
    t0 = time.time()
    try:
        ENGINE = AsrEngine(model=args.model, device=args.device, compute=args.compute)
    except Exception as e:  # noqa: BLE001
        import traceback
        traceback.print_exc()
        STATE["err"] = f"{type(e).__name__}: {e}"
        print(f"[fatal] ASR 加载失败：{STATE['err']}", flush=True)
        return 3
    STATE.update(ready=True, load_ms=round((time.time() - t0) * 1000),
                 model=args.model, device=ENGINE.device, compute=ENGINE.compute)
    print(f"[ready] ASR {args.model} · {ENGINE.describe()} · "
          f"加载+warmup {STATE['load_ms']}ms", flush=True)

    srv = ThreadingHTTPServer((args.host, args.port), Handler)
    srv.daemon_threads = True
    print(f"[listen] http://{args.host}:{args.port}", flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
