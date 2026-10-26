# -*- coding: utf-8 -*-
"""通话设置：一个 JSON，三个入口（网页 / 桌宠 / 环回）共用。

为什么单独抽一个文件：他要求「音色来源」能当**选项**切，而不是改代码。
所以「用哪个 TTS」写在配置里，界面只改这个文件；进程启动时读一次。

本地/云端花钱的事说清楚：
  · piper   —— 本机 ONNX，**完全免费**、离线、0 显存，音色偏播报腔
  · cloud   —— SiliconFlow CosyVoice2，按量计费，**明显更自然**，首字节约 1.3s
  · openai  —— OpenAI 的 gpt-4o-mini-tts，最自然、还能给「语气指令」，但要 key + 走代理
"""
from __future__ import annotations

import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
STATE_DIR = os.path.normpath(os.path.join(HERE, "..", "..", "state", "call"))
CONFIG = os.path.join(STATE_DIR, "config.json")

# 界面上的顺序 = 从免费到花钱
BACKENDS = [
    {"id": "piper",  "label": "本地 piper（免费·离线）", "paid": False},
    {"id": "cloud",  "label": "云端 CosyVoice2（按量计费）", "paid": True},
    {"id": "openai", "label": "OpenAI TTS（需要 key·走代理）", "paid": True},
]

DEFAULTS = {
    "tts": {
        "backend": "piper",
        "piper": {"length_scale": 1.10, "noise_scale": 0.72, "noise_w_scale": 0.90},
        "cloud": {"voice": "anna", "speed": 1.0},
        "openai": {"model": "gpt-4o-mini-tts", "voice": "nova", "base_url": "https://api.openai.com/v1"},
    },
    "asr": {"model": "small", "device": None, "compute": None},
    "call": {"silence_end": 0.90, "max_reply_chars": 25},
}


def _merge(base: dict, over: dict) -> dict:
    out = dict(base)
    for k, v in (over or {}).items():
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = _merge(out[k], v)
        else:
            out[k] = v
    return out


def load() -> dict:
    try:
        with open(CONFIG, "r", encoding="utf-8") as f:
            return _merge(DEFAULTS, json.load(f))
    except Exception:  # noqa: BLE001
        return json.loads(json.dumps(DEFAULTS))


def save(cfg: dict) -> str:
    os.makedirs(STATE_DIR, exist_ok=True)
    with open(CONFIG, "w", encoding="utf-8") as f:
        json.dump(cfg, f, ensure_ascii=False, indent=2)
    return CONFIG


def backend(cfg: dict | None = None) -> str:
    cfg = cfg or load()
    return (cfg.get("tts") or {}).get("backend") or "piper"


def set_backend(be: str, cfg: dict | None = None) -> dict:
    cfg = cfg or load()
    cfg.setdefault("tts", {})["backend"] = be
    save(cfg)
    return cfg


def label_of(be: str) -> str:
    for b in BACKENDS:
        if b["id"] == be:
            return b["label"]
    return be


def next_backend(be: str) -> str:
    ids = [b["id"] for b in BACKENDS]
    try:
        return ids[(ids.index(be) + 1) % len(ids)]
    except ValueError:
        return ids[0]


def main() -> int:
    """命令行：python config.py           看现在的
              python config.py piper     切成某个
              python config.py --list    有哪些"""
    import sys
    args = sys.argv[1:]
    if args and args[0] == "--list":
        for b in BACKENDS:
            print(f"{b['id']:8s} {b['label']}")
        return 0
    cfg = load()
    if args and args[0] in [b["id"] for b in BACKENDS]:
        cfg = set_backend(args[0], cfg)
        print(f"已切到 {args[0]} → {CONFIG}")
    cfg = load()
    cur = backend(cfg)
    print(f"现在的音色来源：{cur}（{label_of(cur)}）")
    for b in BACKENDS:
        mark = "●" if b["id"] == cur else "○"
        print(f"  {mark} {b['id']:8s} {b['label']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
