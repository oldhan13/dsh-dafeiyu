# -*- coding: utf-8 -*-
"""桌宠上的通话：默认麦克风 → 默认扬声器。

跟 webcall.py 的差别只有一个 —— **声音不经过网络**：麦克风在你这台机器上，
她也从这台机器的扬声器出来。所以延迟更低，也不受浏览器/证书那一套影响。

界面那半边（`dafeiyu/pet/call.ps1`）只读这里写的一份状态文件：
    dafeiyu/state/call/petcall.json     { ready, alive, state, level, heard, reply, seconds, turns }
    dafeiyu/state/call/petcall.jsonl    每一轮的流水（事后能翻）
挂断：往 dafeiyu/state/call/petcall.cmd 写一行 hangup（界面会写），或者 Ctrl+C。

用法：
    python petcall.py                 # 打到挂断为止
    python petcall.py --seconds 120   # 两分钟自动挂
    python petcall.py --source loopback --sink cable   # 走 QQ 那条（环回 / 虚拟声卡）
"""
from __future__ import annotations

import json
import os
import sys
import threading
import time

for _s in (sys.stdout, sys.stderr):
    try:
        _s.reconfigure(encoding="utf-8", errors="replace")
    except Exception:  # noqa: BLE001
        pass

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

from engine import CallEngine, MicSource, SpeakerSink, log  # noqa: E402

STATE_DIR = os.path.normpath(os.path.join(HERE, "..", "..", "state", "call"))
JSON = os.path.join(STATE_DIR, "petcall.json")
JSONL = os.path.join(STATE_DIR, "petcall.jsonl")
CMD = os.path.join(STATE_DIR, "petcall.cmd")


class Hud:
    """状态文件的写者。界面每 120ms 读一次，所以这里只要写得原子就行。"""

    def __init__(self):
        os.makedirs(STATE_DIR, exist_ok=True)
        self.lock = threading.Lock()
        self.data = {
            "ready": False, "alive": True, "state": "starting", "level": 0.0,
            "heard": "", "reply": "", "seconds": 0, "turns": 0,
            "first_sound_ms": None, "started": time.time(), "at": time.time(),
        }
        self._stop = threading.Event()
        self._t0 = time.time()

    def set(self, **kw) -> None:
        with self.lock:
            self.data.update(kw)

    def write(self) -> None:
        with self.lock:
            self.data["seconds"] = round(time.time() - self._t0, 1)
            self.data["at"] = time.time()
            blob = json.dumps(self.data, ensure_ascii=False)
        tmp = JSON + ".tmp"
        try:
            with open(tmp, "w", encoding="utf-8") as f:
                f.write(blob)
            os.replace(tmp, JSON)
        except Exception:  # noqa: BLE001
            pass

    def start(self) -> None:
        def loop():
            while not self._stop.is_set():
                self.write()
                time.sleep(0.1)
        threading.Thread(target=loop, daemon=True).start()

    def stop(self) -> None:
        self._stop.set()
        self.set(alive=False, state="idle")
        self.write()


def hangup_requested() -> bool:
    try:
        if not os.path.exists(CMD):
            return False
        with open(CMD, "r", encoding="utf-8", errors="replace") as f:
            return "hangup" in f.read().lower()
    except Exception:  # noqa: BLE001
        return False


def main() -> int:
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--seconds", type=float, default=0, help="0 = 打到挂断为止")
    ap.add_argument("--source", default="mic", choices=["mic", "loopback"])
    ap.add_argument("--sink", default="speaker", choices=["speaker", "cable"])
    ap.add_argument("--device", default=None)
    ap.add_argument("--out-device", default=None)
    ap.add_argument("--tts", default=None, choices=["piper", "sovits", "cloud", "openai"],
                    help="不填就用 config.json 里选的（界面切的就是它）")
    ap.add_argument("--model", default="small")
    ap.add_argument("--asr-device", default=None)
    args = ap.parse_args()

    os.makedirs(STATE_DIR, exist_ok=True)
    for p in (CMD, JSON + ".tmp"):
        try:
            os.remove(p)
        except OSError:
            pass

    hud = Hud()
    hud.start()

    # ★ 通话位：同一时刻只该有一通电话。新的按下去，旧的自己退 —— 由 res.py 仲裁，
    #   不靠「我记着去关」。被顶掉的那一通会走它自己的礼貌通道（petcall 看 petcall.cmd，
    #   webcall 走 /quit），不听话才硬结束。
    taken = None
    try:
        import res
        # ★ 先清「上一通被硬杀」留下的烂摊子（2026-10-26 20:3x）：
        #   被 -Force 打死的电话走不到 release，于是 session.json 留着死 pid、
        #   `wallpaper.paused` 留着记号 —— 动态壁纸会一直停着没人还回去。
        #   reap 只清「记录比现实活得久」的那些，**不杀活着的进程**。
        try:
            res.reap(quiet=True)
        except Exception:  # noqa: BLE001
            pass
        taken = res.claim("petcall", "pet")
        if taken:
            log(f"[接管] 原来那一通（{taken.get('who')} pid {taken.get('pid')}）已让位")
    except Exception as e:  # noqa: BLE001
        log(f"[资源] 通话位没登记上（不影响这一通）：{type(e).__name__}: {e}")

    t0 = time.time()
    try:
        from asr import make_asr
        log(f"[ASR] 要耳朵（常驻服务优先）…")
        asr = make_asr(model=args.model, device=args.asr_device)
        log(f"[ASR] {asr.describe()}")

        import config as cfgmod
        tts_backend = args.tts or cfgmod.backend()
        tts_engine = None
        if tts_backend == "piper":
            import tts as ttsmod
            log("[TTS] 加载本地 piper …")
            tts_engine = ttsmod.piper_from_config()
            log(f"[TTS] piper {tts_engine.load_ms:.0f}ms · 预热 {tts_engine.warmup_ms:.0f}ms")
            log(f"[TTS] 语气 快慢 {tts_engine.syn.length_scale} · 起伏 {tts_engine.syn.noise_w_scale}")
        elif tts_backend == "sovits":
            import tts as ttsmod
            # 她自己的声音住在另一个常驻进程里（模型加载 2s + 预热 5s，不能每通电话都付）。
            # 那个进程没在跑就现在拉起来，等它 ready；拉不起来就让引擎退回 piper，别让电话哑掉。
            log("[TTS] 使用 GPT-SoVITS（她自己的音色）…")
            ok = ttsmod.ensure_sovits()
            log(f"[TTS] sovits {'就绪' if ok else '起不来，这一通会用 piper 顶上'}")
        else:
            log(f"[TTS] 用 {tts_backend}（{cfgmod.label_of(tts_backend)}）")

        sink = SpeakerSink("VB-Audio Virtual Cable" if args.sink == "cable" else args.out_device)

        def on_event(e: dict) -> None:
            t = e.get("t")
            if t == "state":
                hud.set(state=e["state"])
            elif t == "level":
                hud.set(level=e["level"])
            elif t == "heard":
                hud.set(heard=e.get("text", ""))
            elif t == "reply":
                hud.set(reply=e.get("text", ""))
            hud.write()

        eng = CallEngine(asr=asr, tts_backend=tts_backend, tts_engine=tts_engine,
                         sink=sink, on_event=on_event, verbose=True)
        eng.start()
        src = MicSource(eng.feed, device_hint=args.device, loopback=(args.source == "loopback"))
        src.start()

        warm = (time.time() - t0) * 1000
        hud.set(ready=True, state="listening")
        log(f"[就绪] 预热合计 {warm:.0f}ms —— 开始说话吧")
    except Exception as e:  # noqa: BLE001
        log(f"[启动失败] {type(e).__name__}: {e}")
        hud.set(state="failed", heard=f"{type(e).__name__}: {e}")
        hud.stop()
        try:
            res.release("petcall")
        except Exception:  # noqa: BLE001
            pass
        return 3

    deadline = (time.time() + args.seconds) if args.seconds else None
    code = 0
    try:
        while True:
            if hangup_requested():
                log("[挂断] 界面要求挂断")
                break
            if deadline and time.time() > deadline:
                log("[挂断] 到时间了")
                break
            if eng.state == "listening" or eng.state == "speaking":
                last = eng.turns[-1] if eng.turns else None
                hud.set(turns=len(eng.turns),
                        first_sound_ms=(last or {}).get("first_sound_ms"))
            time.sleep(0.15)
    except KeyboardInterrupt:
        log("^C")
    finally:
        try:
            src.stop()
        except Exception:  # noqa: BLE001
            pass
        eng.stop()
        try:
            sink.close()
        except Exception:  # noqa: BLE001
            pass
        # 流水：每一轮都留一行，事后能翻
        try:
            with open(JSONL, "a", encoding="utf-8") as f:
                for t in eng.turns:
                    f.write(json.dumps(dict(t, at_wall=time.strftime("%Y-%m-%d %H:%M:%S")),
                                       ensure_ascii=False) + "\n")
        except Exception:  # noqa: BLE001
            pass
        turns = len(eng.turns)
        hud.set(turns=turns, heard="", reply="", level=0.0)
        hud.stop()
        try:
            os.remove(CMD)
        except OSError:
            pass
        # 交还通话位（只交还自己那份，别把别人的位子误删）
        try:
            res.release("petcall")
        except Exception:  # noqa: BLE001
            pass
        log(f"[结束] {turns} 轮")

    return code


if __name__ == "__main__":
    sys.exit(main())
