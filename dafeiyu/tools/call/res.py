# -*- coding: utf-8 -*-
"""资源管家：谁在什么时候占什么，由一张表说了算，而不是靠人记得去关。

为什么要有它（2026-10-26 19:2x 他说的）：
    他原话「问题不是占用资源，而是我们要把资源放到合理的规划的位置，
    一味关掉是没有用的，我们要从根源上解决问题」。
    当时实测：显存 **2597 / 16303 MiB** —— 根本没满。所以「关掉 webcall」从来不是在解决
    容量问题，它只是在掩盖「**没有任何东西负责生命周期**」这件事：谁想拿就拿，拿了不放，
    谁该活着完全取决于「上次是谁起的」。

所以这里只做三件事，一件一个位置：

    ① 预算（BUDGET）
       卡一共多少、给桌面留多少、每个模型声明要多少。超了**报警**，不静默、也不擅自杀。

    ② 归属（session.json）
       同一时刻只该有**一通电话**。新的按下去了，旧的自己退 —— 由这里仲裁，
       不靠「我记着去关」。

    ③ 周转（不在本文件里，但规则从这里出）
       sovits 空闲 ⇒ 把模型还给显卡（壳留着，下次醒只要 2s）；
       webcall 空转 ⇒ 自己退。**重的东西按需进来、按闲出去**，这样「关不关」就不再是个需要人管的事。

用法：
    python res.py                 # 看现在谁占着什么（人看的表）
    python res.py --json          # 同一份数据，给别的脚本吃
    python res.py reap            # 清死锁 / 清残留（不负责杀活着的进程）
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

for _s in (sys.stdout, sys.stderr):
    try:
        _s.reconfigure(encoding="utf-8", errors="replace")
    except Exception:  # noqa: BLE001
        pass

HERE = os.path.dirname(os.path.abspath(__file__))
STATE = os.path.normpath(os.path.join(HERE, "..", "..", "state", "call"))
SESSION = os.path.join(STATE, "session.json")
PETCMD = os.path.join(STATE, "petcall.cmd")
SOVITS_PORT = 9880
ASR_PORT = 9890
WEBCALL_PORT = 8443

# ★ 预算：这是「规划」落地的地方。数字写在这里，才有东西能对账。
#   不是配额限制（超了不杀），是**声明**：谁要用多少，先写下来。
BUDGET = {
    "gpu_total_mb": 16303,
    "desktop_reserve_mb": 1200,      # Windows 桌面 / 浏览器合成，不算我们的
    "declared": {
        "asr": 700,                  # faster-whisper small fp16（petcall / webcall 各一份）
        "sovits": 1300,              # GPT-SoVITS v2 四个权重一起
        "piper": 0,                  # CPU
    },
}


# ------------------------------------------------------------------ 让位：动态壁纸

# ★ 2026-10-26 19:4x 他说的：「CPU 没有占用，而是 GPU0 有 100% 的占用」。
#   实测（Get-Counter '\GPU Engine(*)\Utilization Percentage'，一直开着的那通电话期间）：
#     wallpaper64  videodecode 81.8% + videoprocessing 52.1%
#     dwm          3d 60.7%
#   而 5080 是 0% / 4.3W。⇒ 卡的**不是算力，是画面输出这条管线**：
#   动态壁纸把核显的视频解码引擎压满了，桌面合成（dwm）跟着堵，电话里窗口又多一点动画，
#   整机就开始顿。它不是我们的进程，但**我们能在通话期间让它让位、挂断再还回去** ——
#   这就是「把资源放到合理的位置」，不是「关掉」。
WALLPAPER_MARK = os.path.join(STATE, "wallpaper.paused")


def _wallpaper_exe() -> str | None:
    cands = [os.environ.get("WALLPAPER_EXE"),
             r"D:\Steam\steamapps\common\wallpaper_engine\wallpaper64.exe",
             r"C:\Program Files (x86)\Steam\steamapps\common\wallpaper_engine\wallpaper64.exe",
             r"C:\Program Files\Steam\steamapps\common\wallpaper_engine\wallpaper64.exe"]
    for c in cands:
        if c and os.path.exists(c):
            return c
    return None


def wallpaper(action: str, quiet: bool = True) -> bool:
    """让动态壁纸 `pause` / `play`。做不成就算了，**绝不许因为它把电话挡住**。"""
    exe = _wallpaper_exe()
    if not exe:
        return False
    try:
        subprocess.run([exe, "-control", action], capture_output=True, timeout=10)
    except Exception:  # noqa: BLE001
        return False
    # 留个记号：万一一通电话被硬杀、没人来 release，下次就能把它还回去
    try:
        if action == "pause":
            with open(WALLPAPER_MARK, "w", encoding="utf-8") as f:
                f.write(time.strftime("%Y-%m-%d %H:%M:%S"))
        elif os.path.exists(WALLPAPER_MARK):
            os.remove(WALLPAPER_MARK)
    except OSError:
        pass
    if not quiet:
        print(f"[让位] 动态壁纸 {action}", flush=True)
    return True


def _yield_screen() -> bool:
    try:
        import config as cfgmod
        return bool((cfgmod.load().get("call") or {}).get("yield_wallpaper", True))
    except Exception:  # noqa: BLE001
        return True


# ------------------------------------------------------------------ 进程存活

def _alive(pid) -> bool:
    """★ 别用 os.kill(pid, 0) —— 在 Windows 上信号 0 也会走 TerminateProcess，
    那等于「查一下活没活」顺手把人杀了。用 OpenProcess 问退出码才安全。"""
    try:
        pid = int(pid)
    except (TypeError, ValueError):
        return False
    if pid <= 0:
        return False
    try:
        import ctypes
        k32 = ctypes.windll.kernel32
        h = k32.OpenProcess(0x1000, False, pid)          # QUERY_LIMITED_INFORMATION
        if not h:
            return False
        code = ctypes.c_ulong()
        ok = k32.GetExitCodeProcess(h, ctypes.byref(code))
        k32.CloseHandle(h)
        return bool(ok) and code.value == 259            # STILL_ACTIVE
    except Exception:  # noqa: BLE001
        return False


def _terminate(pid, wait: float = 3.0) -> bool:
    try:
        subprocess.run(["taskkill", "/PID", str(int(pid)), "/F"],
                       capture_output=True, timeout=15)
    except Exception:  # noqa: BLE001
        return False
    end = time.time() + wait
    while time.time() < end:
        if not _alive(pid):
            return True
        time.sleep(0.15)
    return not _alive(pid)


# ------------------------------------------------------------------ 会话（归属）

def read_session() -> dict | None:
    try:
        with open(SESSION, "r", encoding="utf-8") as f:
            rec = json.load(f)
        return rec if isinstance(rec, dict) else None
    except Exception:  # noqa: BLE001
        return None


def _write_session(rec: dict) -> None:
    os.makedirs(STATE, exist_ok=True)
    tmp = SESSION + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(rec, f, ensure_ascii=False)
    os.replace(tmp, SESSION)


def release(who: str | None = None) -> bool:
    """交还会话位。who 给了就只在**自己**持有时才删（别把别人的位子误删）。"""
    rec = read_session()
    if rec is None:
        return False
    if who and rec.get("who") != who:
        return False
    try:
        os.remove(SESSION)
    except OSError:
        return False
    # 通话结束 ⇒ 把画面那条管线还回去（动态壁纸继续放）
    if _yield_screen():
        wallpaper("play")
    return True


def _evict(rec: dict, quiet: bool = False) -> None:
    """让位给新来的。先走**礼貌通道**，对方不理才动手。"""
    who = rec.get("who")
    pid = rec.get("pid")
    kind = rec.get("kind")
    if not _alive(pid):
        return
    if not quiet:
        print(f"[接管] {who}(pid {pid}) 还在占着通话位，让它退", flush=True)

    if kind == "pet" or who == "petcall":
        try:                     # petcall 每 150ms 读一次这个文件
            with open(PETCMD, "w", encoding="utf-8") as f:
                f.write("hangup")
        except OSError:
            pass
        end = time.time() + 10.0
        while time.time() < end:
            if not _alive(pid):
                return
            time.sleep(0.2)
    elif kind == "web" or who == "webcall":
        # ★ 2026-10-26 19:28 的坑：网页通话是 **https**，而这里一开始拼的是 `http://…/quit`
        #   ⇒ 握手失败 → 礼貌通道等于没有 → 直接落到 taskkill（对方连日志都没留一行）。
        #   所以让 webcall 登记自己的完整地址（含协议），不要在这里猜。
        port = rec.get("port") or WEBCALL_PORT
        url = rec.get("url") or f"http://127.0.0.1:{port}/quit"
        try:
            ctx = None
            if url.startswith("https"):
                import ssl
                ctx = ssl.create_default_context()
                ctx.check_hostname = False
                ctx.verify_mode = ssl.CERT_NONE        # 自签证书，本机自连
            with urllib.request.urlopen(url, timeout=3.0, context=ctx):
                pass
        except Exception:  # noqa: BLE001
            pass
        end = time.time() + 6.0
        while time.time() < end:
            if not _alive(pid):
                return
            time.sleep(0.2)

    # 礼貌不通就来硬的 —— 但只在「新的一通要开始」这一件事上，不做别的
    if _terminate(pid) and not quiet:
        print(f"[接管] {who}(pid {pid}) 不肯自己退，已结束", flush=True)


def claim(who: str, kind: str, port: int | None = None,
          url: str | None = None) -> dict | None:
    """抢通话位。**最新的意图赢** —— 他在桌宠上按下通话，就该是桌宠那通。

    `url` 是「让位通道」的完整地址（webcall 走 https，要带上协议）。
    返回被顶掉的那条记录（没有就是 None），方便调用方打一行日志。
    """
    old = read_session()
    if old and old.get("who") != who and _alive(old.get("pid")):
        _evict(old)
        if _alive(old.get("pid")):
            # 走到这里说明礼貌通道和硬结束都没成 —— 宁可说出来，也别假装位子是空的
            print(f"[warn] {old.get('who')}(pid {old.get('pid')}) 还活着，"
                  f"可能有两路同时在听", flush=True)
    rec = {"who": who, "kind": kind, "pid": os.getpid(),
           "port": port, "url": url, "at": round(time.time(), 3)}
    _write_session(rec)
    # 通话开始 ⇒ 让动态壁纸先退场：核显的视频解码引擎被它压满时，桌面会跟着堵
    if _yield_screen():
        wallpaper("pause")
    return old if (old and old.get("who") != who) else None


# ------------------------------------------------------------------ 采集

def _scan_procs() -> list[dict]:
    ps = (
        "$ErrorActionPreference='SilentlyContinue';"
        "Get-CimInstance Win32_Process -Filter \"Name='python.exe'\" |"
        " ForEach-Object { [pscustomobject]@{pid=$_.ProcessId;"
        " start=$_.CreationDate.ToString('HH:mm:ss'); cmd=$_.CommandLine } } |"
        " ConvertTo-Json -Compress"
    )
    try:
        out = subprocess.run(
            ["powershell", "-NoProfile", "-NonInteractive", "-Command", ps],
            capture_output=True, text=True, timeout=25,
            encoding="utf-8", errors="replace").stdout.strip()
        if not out:
            return []
        data = json.loads(out)
        if isinstance(data, dict):
            data = [data]
    except Exception:  # noqa: BLE001
        return []
    keys = ("petcall.py", "webcall.py", "sovits_server.py", "asr_server.py", "listen.py", "loop.py")
    rows = []
    for d in data:
        cmd = d.get("cmd") or ""
        hit = next((k for k in keys if k in cmd), None)
        if not hit:
            continue
        rows.append({"pid": d.get("pid"), "start": d.get("start"),
                     "what": hit.replace(".py", ""), "cmd": cmd})
    return rows


def gpu() -> dict:
    try:
        out = subprocess.run(
            ["nvidia-smi", "--query-gpu=memory.total,memory.used,memory.free,power.draw",
             "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=15).stdout.strip()
        total, used, free, power = [s.strip() for s in out.split(",")[:4]]
        return {"total_mb": int(float(total)), "used_mb": int(float(used)),
                "free_mb": int(float(free)), "power_w": float(power)}
    except Exception:  # noqa: BLE001
        return {}


def sovits_health(timeout: float = 1.5) -> dict | None:
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{SOVITS_PORT}/health",
                                    timeout=timeout) as r:
            return json.loads(r.read().decode("utf-8"))
    except Exception:  # noqa: BLE001
        return None


def _listening(port: int) -> int | None:
    try:
        out = subprocess.run(["netstat", "-ano"], capture_output=True, text=True,
                             timeout=15, encoding="utf-8", errors="replace").stdout
    except Exception:  # noqa: BLE001
        return None
    for line in out.splitlines():
        parts = line.split()
        if len(parts) >= 5 and parts[0].upper().startswith("TCP") and \
                parts[1].endswith(f":{port}") and parts[3].upper() == "LISTENING":
            try:
                return int(parts[4])
            except ValueError:
                return None
    return None


def snapshot() -> dict:
    g = gpu()
    sess = read_session()
    hs = sovits_health()
    declared = sum(BUDGET["declared"].values())
    usable = max(0, BUDGET["gpu_total_mb"] - BUDGET["desktop_reserve_mb"])
    return {
        "at": time.strftime("%Y-%m-%d %H:%M:%S"),
        "gpu": g,
        "budget": {
            "declared_mb": declared,
            "usable_mb": usable,
            "headroom_mb": (g.get("used_mb", 0) - declared) if g else None,
        },
        "session": sess,
        "session_alive": bool(sess and _alive(sess.get("pid"))),
        "sovits": ({"ok": hs.get("ok"), "sleeping": hs.get("sleeping"),
                    "load_ms": hs.get("load_ms"), "vram_mb": hs.get("vram_mb"),
                    "speak_reqs": hs.get("speak_reqs")} if hs else None),
        "ports": {"webcall": _listening(WEBCALL_PORT), "sovits": _listening(SOVITS_PORT),
                  "asr": _listening(ASR_PORT)},
        "procs": _scan_procs(),
    }


# ------------------------------------------------------------------ 输出

def report(s: dict | None = None) -> str:
    s = s or snapshot()
    L = [f"资源现状 {s['at']}"]
    g = s.get("gpu") or {}
    b = s["budget"]
    if g:
        bar = f"{g['used_mb']} / {g['total_mb']} MiB（余 {g['free_mb']}）  {g['power_w']:.0f}W"
        L.append(f"  显卡   {bar}")
    L.append(f"  预算   声明 {b['declared_mb']}MB · 可用 {b['usable_mb']}MB"
             f" · 实际还空 {g.get('free_mb', '?')}MB")

    sess = s.get("session")
    if sess:
        tag = "活着" if s.get("session_alive") else "★ 记录还在但进程已死（reap 可清）"
        L.append(f"  通话位 {sess.get('who')}（{sess.get('kind')}，pid {sess.get('pid')}，{tag}）")
    else:
        L.append("  通话位 空 —— 现在没有人在打电话")

    so = s.get("sovits")
    if so is None:
        L.append("  sovits 没起（打第一通电话时会自动拉起）")
    elif so.get("ok"):
        L.append(f"  sovits 醒着 · 模型 {so.get('load_ms')}ms · 自报 {so.get('vram_mb')}MB"
                 f" · 说过 {so.get('speak_reqs')} 句")
    elif so.get("sleeping"):
        L.append("  sovits 睡着（进程在，模型已还给显卡 —— 下次要一句话时自己醒）")
    else:
        L.append("  sovits 起来了但模型没就绪（日志里看原因）")

    p = s["ports"]
    L.append(f"  端口   8443 {'监听中' if p['webcall'] else '没监听'}"
             f" · 9880 {'监听中' if p['sovits'] else '没监听'}"
             f" · 9890 {'监听中' if p.get('asr') else '没监听'}（耳朵）")

    procs = s.get("procs") or []
    if not procs:
        L.append("  进程   （没有通话相关的 python 进程）")
    else:
        L.append("  进程")
        for r in procs:
            L.append(f"    {r['what']:<8} pid {r['pid']:<8} 起于 {r['start']}")
    return "\n".join(L)


def reap(quiet: bool = False) -> list[str]:
    """清掉「记录比现实活得久」的东西。**不杀活着的进程** —— 那是 claim 的事。"""
    msgs = []
    sess = read_session()
    if sess and not _alive(sess.get("pid")):
        try:
            os.remove(SESSION)
        except OSError:
            pass
        msgs.append(f"清掉死掉的通话位记录（{sess.get('who')} pid {sess.get('pid')}）")
    if os.path.exists(PETCMD):
        try:
            os.remove(PETCMD)
            msgs.append("清掉残留的 petcall.cmd")
        except OSError:
            pass
    # 没有人在打电话、却留着「壁纸已暂停」的记号 ⇒ 上一通是被硬杀/断掉的，把它还回去
    if read_session() is None and os.path.exists(WALLPAPER_MARK):
        wallpaper("play")
        msgs.append("把动态壁纸还回去了（上一通没走正常收尾）")
    if not quiet:
        print("\n".join(msgs) if msgs else "没有要清的")
    return msgs


def main() -> int:
    args = sys.argv[1:]
    if "--json" in args:
        print(json.dumps(snapshot(), ensure_ascii=False, indent=2))
        return 0
    if "reap" in args:
        return 0 if reap() else 0
    print(report())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
