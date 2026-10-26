# -*- coding: utf-8 -*-
"""试听一句：按**配置里选的那个音色来源**合成一句话，落一个 wav，给界面播。

为什么单独一个脚本：界面里那个「试听」按钮不能自己实现一套合成长度 ——
它必须走引擎**同一条路**（`tts.make_stream`），否则试听好听、打电话却是另一回事。
这个脚本就干这一件事：一条路、一句、一个 wav。

用法：
    python voice-test.py                       # 用配置里选的，默认那句
    python voice-test.py --backend piper       # 不听配置，试指定后端
    python voice-test.py --text "听得见吗" --backend cloud
    python voice-test.py --text-file x.txt     # 中文不过命令行（这台机器 ACP=936）
输出（最后一行是 JSON）：
    {"ok":true,"wav":"…","backend":"piper","rate":22050,"dur_s":2.4,"first_ms":106,"total_ms":320}
界面读到 wav 就用 System.Media.SoundPlayer 放，不再依赖别的播放器。
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
import wave

for _s in (sys.stdout, sys.stderr):
    try:
        _s.reconfigure(encoding="utf-8", errors="replace")
    except Exception:  # noqa: BLE001
        pass

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import numpy as np  # noqa: E402

import config as cfgmod  # noqa: E402
import tts  # noqa: E402

OUTDIR = cfgmod.STATE_DIR
DEFAULT_TEXT = "嗯，我在呢。你说吧，今天过得怎么样？"


def _fail(msg: str, **kw) -> int:
    print(json.dumps({"ok": False, "err": msg, **kw}, ensure_ascii=False))
    return 1


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--backend", default=None)
    ap.add_argument("--text", default=None)
    ap.add_argument("--text-file", default=None)
    ap.add_argument("--json-out", default=None, help="把结果再写一份到这里（界面读它）")
    ap.add_argument("--no-start", action="store_true", help="不许自己拉起常驻服务（调试用）")
    args = ap.parse_args()

    text = args.text
    if args.text_file:
        try:
            with open(args.text_file, "r", encoding="utf-8-sig") as f:
                text = f.read().strip()
        except Exception as e:  # noqa: BLE001
            return _fail(f"读不了词文件：{e}")
    text = (text or DEFAULT_TEXT).strip()

    cfg = cfgmod.load()
    backend = args.backend or cfgmod.backend(cfg)
    ids = [b["id"] for b in cfgmod.BACKENDS]
    if backend not in ids:
        return _fail(f"没有这个音色来源：{backend}（可选：{', '.join(ids)}）")

    # 本地 SoVITS 是另一个常驻服务：第一句前把它拉起来（冷启动二十几秒，所以先说一声）
    if backend == "sovits" and not args.no_start:
        h = tts.sovits_health()
        if not (h and h.get("ok")):
            print(f"[试听] {backend} 的服务没在跑，拉起来（冷启动约 20~30 秒，等一下）…", flush=True)
            ok = tts.ensure_sovits(timeout=120.0)
            if not ok:
                return _fail("GPT-SoVITS 服务起不来 —— 本机没装好它，或者端口被占。"
                             "这条不是必须的，换成 piper 或 cloud 就行。")

    stats: dict = {}
    t0 = time.time()
    try:
        rate, gen = tts.make_stream(backend, text, stats=stats)
        chunks = []
        for arr in gen:
            a = np.asarray(arr, dtype="float32").ravel()
            if len(a):
                chunks.append(a)
    except Exception as e:  # noqa: BLE001
        hint = ""
        if backend == "piper":
            hint = (" —— 多半是 piper 音色模型没下：界面里点「装依赖 / 下载音色」，"
                    "或命令行跑 python bootstrap.py --piper")
        elif backend == "cloud":
            hint = f" —— 看看 {os.path.expanduser('~')}\\.dsh\\siliconflow-key.txt 里有没有 key"
        elif backend == "openai":
            hint = " —— 看看 ~\\.dsh\\openai-key.txt 里有没有 key，以及能不能连上 api.openai.com"
        elif backend == "sovits":
            hint = " —— 服务在不在 9880"
        return _fail(f"{type(e).__name__}: {e}{hint}", backend=backend)

    if not chunks:
        return _fail("合成出来是空的（0 个样点）", backend=backend)

    audio = np.concatenate(chunks)
    peak = float(np.max(np.abs(audio))) if len(audio) else 0.0
    rms = float(np.sqrt(np.mean(audio ** 2))) if len(audio) else 0.0
    # ★ 削波判据（2026-10-26 那次「炸」的教训）：RMS 0.91 + 削波 100% 听着还像人声，
    #   但那是满幅方波。所以这里不只看「有没有声」，把这两个数也吐出来。
    clipped = float(np.mean(np.abs(audio) >= 0.999)) * 100.0

    os.makedirs(OUTDIR, exist_ok=True)
    path = os.path.join(OUTDIR, f"voice-test-{int(time.time() * 1000)}.wav")
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(int(rate))
        w.writeframes((np.clip(audio, -1.0, 1.0) * 32767.0).astype("<i2").tobytes())

    out = {
        "ok": True, "wav": path, "backend": backend,
        "label": cfgmod.label_of(backend), "rate": int(rate),
        "dur_s": round(len(audio) / float(rate), 2),
        "first_ms": int(stats.get("first_chunk_ms") or 0),
        "total_ms": int(stats.get("total_ms") or round((time.time() - t0) * 1000)),
        "rms": round(rms, 3), "peak": round(peak, 3), "clipped_pct": round(clipped, 2),
        "text": text,
    }
    print(json.dumps(out, ensure_ascii=False))
    if args.json_out:
        try:
            with open(args.json_out, "w", encoding="utf-8") as f:
                json.dump(out, f, ensure_ascii=False)
        except Exception:  # noqa: BLE001
            pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
