# -*- coding: utf-8 -*-
"""桌宠上的通话：默认麦克风 → 默认扬声器。

跟 webcall.py 的差别只有一个 —— **声音不经过网络**：麦克风在你这台机器上，
她也从这台机器的扬声器出来。所以延迟更低，也不受浏览器/证书那一套影响。

界面那半边（`dafeiyu/pet/call.ps1`）只读这里写的一份状态文件：
    dafeiyu/state/call/petcall.json     { ready, alive, state, level, heard, reply, seconds, turns, mic, out }
    dafeiyu/state/call/petcall.jsonl    每一轮的流水（事后能翻）
界面写的命令也在这份 state 目录里：dafeiyu/state/call/petcall.cmd
    hangup         挂断
    mic on|off     闭麦（off = 不听）
    out on|off     静音（off = 她不出声，只留文字）
或者 Ctrl+C。

用法：
    python petcall.py                 # 打到挂断为止
    python petcall.py --seconds 120   # 两分钟自动挂
    python petcall.py --source loopback --sink cable   # 走 QQ 那条（环回 / 虚拟声卡）
"""
from __future__ import annotations

import json
import os
import re
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
            # 闭麦 / 静音：界面按下就画成「已停」，所以必须由这里回读，不能只靠界面自己记
            "mic": False, "out": False,
            # 这一通走哪条路（local = 麦克风+喇叭；qq = 喇叭环回 + VB-Cable）
            "mode": "local",
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


def read_cmd() -> dict:
    """界面写的那张小纸条。**只表达「现在要什么」，不表达「刚发生了什么」** ——
    同样的内容读一百遍都是同一个意思，所以「读到一半」不算事故，下一轮 150ms 就补上。
    """
    out = {"hangup": False, "mic": None, "out": None}
    try:
        if not os.path.exists(CMD):
            return out
        with open(CMD, "r", encoding="utf-8", errors="replace") as f:
            text = f.read().lower()
    except Exception:  # noqa: BLE001
        return out
    out["hangup"] = "hangup" in text
    m = re.search(r"mic\s+(on|off)", text)
    if m:
        out["mic"] = m.group(1) == "off"      # 闭麦 = 不听
    m = re.search(r"out\s+(on|off)", text)
    if m:
        out["out"] = m.group(1) == "off"      # 静音 = 她不出声
    return out


def hangup_requested() -> bool:
    return read_cmd()["hangup"]


# ---------------------------------------------------------------- 这一通听哪儿、说哪儿
# ★ 2026-10-26 22:5x 「第二套方案」：QQ 通话那条路。
#   本机通话：麦克风 → 喇叭（默认）。
#   QQ 通话：**默认喇叭的环回**（QQ 那头在说什么）→ **VB-Cable 的播放端**（QQ 的麦克风听这个）。
#     ⇒ 两条腿都在这台机器上实测过（C:\dsh-temp\qq-route-test.py），不是照文档抄的。
def qq_mode_wanted(args) -> bool:
    """走不走 QQ 那条路。命令行优先，其次看 config.json 的 call.qq_mode。"""
    if getattr(args, "qq", False):
        return True
    if getattr(args, "source", None) or getattr(args, "sink", None):
        return False                      # 命令行自己点了设备 ⇒ 那个人说了算
    try:
        import config as cfgmod
        raw = ((cfgmod.load() or {}).get("call") or {}).get("qq_mode", False)
    except Exception:  # noqa: BLE001
        return False
    if isinstance(raw, bool):
        return raw
    return str(raw).strip().lower() in ("1", "true", "yes", "on", "开")


def resolve_io(args) -> tuple:
    """→ (source, sink, qq_mode)"""
    qq = qq_mode_wanted(args)
    source = args.source or ("loopback" if qq else "mic")
    sink = args.sink or ("cable" if qq else "speaker")
    return source, sink, qq


def main() -> int:
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--seconds", type=float, default=0, help="0 = 打到挂断为止")
    ap.add_argument("--source", default=None, choices=["mic", "loopback"],
                    help="不填就按 config.json 的 call.qq_mode 决定（开了=loopback）")
    ap.add_argument("--sink", default=None, choices=["speaker", "cable"],
                    help="不填就按 config.json 的 call.qq_mode 决定（开了=cable）")
    ap.add_argument("--qq", action="store_true",
                    help="强制走 QQ 那条路（听喇叭环回、说进 VB-Cable）")
    ap.add_argument("--device", default=None)
    ap.add_argument("--out-device", default=None)
    ap.add_argument("--tts", default=None, choices=["piper", "sovits", "cloud", "openai"],
                    help="不填就用 config.json 里选的（界面切的就是它）")
    ap.add_argument("--model", default="small")
    ap.add_argument("--asr-device", default=None)
    args = ap.parse_args()
    source, sink_kind, qq_mode = resolve_io(args)

    os.makedirs(STATE_DIR, exist_ok=True)
    for p in (CMD, JSON + ".tmp"):
        try:
            os.remove(p)
        except OSError:
            pass

    hud = Hud()
    hud.start()
    hud.set(mode="qq" if qq_mode else "local")
    log(f"[路] {'QQ 通话（虚拟声卡）' if qq_mode else '本机通话'}：听 {source} · 说 {sink_kind}")

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

        sink = SpeakerSink("VB-Audio Virtual Cable" if sink_kind == "cable" else args.out_device)

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
            elif t == "mic":
                hud.set(mic=bool(e.get("muted")))
            elif t == "out":
                hud.set(out=bool(e.get("muted")))
            hud.write()

        eng = CallEngine(asr=asr, tts_backend=tts_backend, tts_engine=tts_engine,
                         sink=sink, on_event=on_event, verbose=True)
        eng.start()
        src = MicSource(eng.feed, device_hint=args.device, loopback=(source == "loopback"))
        src.start()

        warm = (time.time() - t0) * 1000
        hud.set(ready=True, state="listening", mic=False, out=False)
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
            cmd = read_cmd()
            if cmd["hangup"]:
                log("[挂断] 界面要求挂断")
                break
            # 闭麦 / 静音：状态是「一直是这个」，不是「收到一次」——所以对比着来
            if cmd["mic"] is not None and cmd["mic"] != eng.mic_muted:
                eng.set_mic_muted(cmd["mic"])
                hud.set(mic=eng.mic_muted)
            if cmd["out"] is not None and cmd["out"] != eng.out_muted:
                eng.set_out_muted(cmd["out"])
                hud.set(out=eng.out_muted)
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
