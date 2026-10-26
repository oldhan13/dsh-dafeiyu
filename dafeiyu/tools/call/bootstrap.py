# -*- coding: utf-8 -*-
"""通话那套的「装好它」—— 一条命令一步，界面照着一条条点。

为什么要有这个：`pip install -r requirements.txt` 本身不难，难的是**装到哪个 python 里**。
这台机器上踩过一次：`.venv` 建了一半、依赖没装全，而 `call.ps1` 起的是 PATH 里那个
系统 python —— 于是「装过了」和「跑不起来」同时成立，谁也说不清。
⇒ 统一一条规矩（call.ps1 与这里都照它走）：
     **有 `tools\\call\\.venv\\Scripts\\python.exe` 就用它，没有才用 PATH 里的 python**
   装也装进那一个，跑也从那一个跑。

用法（每一步都能单独跑，断了重跑会接着来）：
    python bootstrap.py --check            只看：缺什么，打 ✓ / ✗
    python bootstrap.py --venv             建 .venv
    python bootstrap.py --deps            .venv 里装 requirements.txt
    python bootstrap.py --piper            下 piper 音色模型（63MB，免费后端要它）
    python bootstrap.py --whisper small    预先下耳朵模型（省得第一通电话干等）
    python bootstrap.py --asr              把常驻耳朵拉起来（已在跑就只回报）
    python bootstrap.py --asr-restart      换过模型之后重启耳朵
    python bootstrap.py --all              = venv + deps + piper
    python bootstrap.py --which            只打印「装/跑用哪个 python」（给界面取用）
    python bootstrap.py --deps --mirror tuna   走清华镜像装（国内网络必备；也认 URL）
⚠️ 这个文件**只用标准库** —— 它得在「依赖还没装好」的那个 python 里也能跑。
⚠️ **不做 `pip install --upgrade pip`**：Windows 上那一步会卡半小时（实测），
   而 venv 自带那版 pip 装这些包够用。别加回来。
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
import urllib.request

for _s in (sys.stdout, sys.stderr):
    try:
        _s.reconfigure(encoding="utf-8", errors="replace")
    except Exception:  # noqa: BLE001
        pass

HERE = os.path.dirname(os.path.abspath(__file__))
VENV_PY = os.path.join(HERE, ".venv", "Scripts", "python.exe")
VENV_MARK = os.path.join(HERE, ".venv", ".deps-ok")   # 依赖装齐过才写下这个（见 target_python）
REQ = os.path.join(HERE, "requirements.txt")
PIPER_DIR = os.path.normpath(os.path.join(HERE, "..", "..", "state", "tts", "piper"))
PIPER_ONNX = os.path.join(PIPER_DIR, "zh_CN-huayan-medium.onnx")
PIPER_JSON = PIPER_ONNX + ".json"
PIPER_URLS = [
    "https://hf-mirror.com/rhasspy/piper-voices/resolve/main/zh/zh_CN/huayan/medium/",
    "https://huggingface.co/rhasspy/piper-voices/resolve/main/zh/zh_CN/huayan/medium/",
]

# requirements.txt 里的名字 → import 名（有几个对不上）
IMPORT_NAME = {
    "piper-tts": "piper",
    "soundcard": "soundcard",
    "faster-whisper": "faster_whisper",
}


def say(msg: str) -> None:
    print(msg, flush=True)


def install_python() -> str:
    """装依赖时往哪个 python 装：有 .venv 就装 .venv（哪怕它还没装全）。"""
    if os.path.exists(VENV_PY):
        return VENV_PY
    return sys.executable


def target_python() -> tuple[str, bool]:
    """**跑**的时候用哪个 python。★ call.ps1 里那三行照这个来。

    ⚠️ 光有 `.venv` 不算数：从前那台机器上就留着半个 .venv（只有 numpy），
       要是照"有 .venv 就用它"起，通话会当场 import 失败 —— 而它之前明明能用
       （系统 python 里装齐了）。所以判据是**依赖装齐过的记号** `VENV_MARK`。
    """
    if os.path.exists(VENV_PY) and os.path.exists(VENV_MARK):
        return VENV_PY, True
    return sys.executable, False


def reqs() -> list[str]:
    out = []
    try:
        with open(REQ, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                name = line.split(">")[0].split("=")[0].split("<")[0].split("[")[0].strip()
                if name:
                    out.append(name)
    except FileNotFoundError:
        out = ["numpy", "scipy", "soundfile", "SoundCard", "faster-whisper", "ctranslate2",
               "piper-tts", "websockets", "cryptography"]
    return out


def probe_deps(py: str) -> dict:
    """在那个 python 里逐个 import，回报缺谁（一次子进程，别在主进程里 import）。"""
    names = reqs()
    mods = {n: IMPORT_NAME.get(n.lower(), n.replace("-", "_").lower()) for n in names}
    code = (
        "import json,sys\n"
        "out={}\n"
        "for m in sys.argv[1:]:\n"
        "    try:\n"
        "        __import__(m); out[m]='ok'\n"
        "    except Exception as e:\n"
        "        out[m]=type(e).__name__\n"
        "print(json.dumps(out))\n"
    )
    try:
        r = subprocess.run([py, "-c", code, *mods.values()], capture_output=True, text=True,
                           encoding="utf-8", errors="replace", timeout=180)
        got = json.loads((r.stdout or "{}").strip().splitlines()[-1]) if r.stdout.strip() else {}
    except Exception:  # noqa: BLE001
        got = {}
    missing = [n for n, m in mods.items() if got.get(m) != "ok"]
    return {"ok": not missing, "missing": missing, "detail": got}


def _write_check(d: dict) -> None:
    """检查结果落一份给界面读（界面不该为了画一行状态去起一个 python 进程）。"""
    try:
        p = os.path.join(os.path.normpath(os.path.join(HERE, "..", "..", "state", "call")),
                         "bootstrap-check.json")
        os.makedirs(os.path.dirname(p), exist_ok=True)
        d = dict(d)
        d["at"] = time.strftime("%Y-%m-%d %H:%M:%S")
        with open(p, "w", encoding="utf-8") as f:
            json.dump(d, f, ensure_ascii=False, indent=2)
    except Exception:  # noqa: BLE001
        pass


def cmd_check() -> int:
    py, is_venv = target_python()
    say(f"跑用：{py}{'（.venv）' if is_venv else '（PATH 里的那个）'}")
    if os.path.exists(VENV_PY) and not is_venv:
        say(f"  · .venv 在，但依赖没装齐过 —— 装了就会改用它：{VENV_PY}")
    out = {"python": py, "venv": is_venv, "ver": None, "py_ok": True,
           "deps_ok": False, "missing": [], "piper": os.path.exists(PIPER_ONNX),
           "piper_json": os.path.exists(PIPER_JSON), "backend": None, "asr_model": None}
    try:
        v = subprocess.run([py, "-c", "import sys;print(sys.version.split()[0])"],
                           capture_output=True, text=True, timeout=60).stdout.strip()
        out["ver"] = v
        say(f"版本：{v}")
        major, minor = (int(x) for x in v.split(".")[:2])
        if (major, minor) < (3, 10):
            out["py_ok"] = False
            say("✗ 要 Python 3.10 以上（faster-whisper 起不来）")
    except Exception as e:  # noqa: BLE001
        out["py_ok"] = False
        say(f"✗ 问不到版本：{e}")

    d = probe_deps(py)
    out["deps_ok"] = d["ok"]
    out["missing"] = d["missing"]
    if d["ok"]:
        say("✓ 依赖齐了")
    else:
        say(f"✗ 还缺 {len(d['missing'])} 个：{', '.join(d['missing'])}")

    if out["piper"]:
        mb = os.path.getsize(PIPER_ONNX) / 1024 / 1024
        say(f"✓ piper 音色模型在（{mb:.0f}MB）")
        if not out["piper_json"]:
            say("✗ 少了同名 .json（音色配置）—— 跑 --piper 补齐")
    else:
        say("✗ piper 音色模型没下（免费后端 piper 要用它）")

    try:
        import config as cfgmod
        cfg = cfgmod.load()
        out["backend"] = cfgmod.backend(cfg)
        out["asr_model"] = (cfg.get("asr") or {}).get("model")
        say(f"音色来源：{out['backend']}（{cfgmod.label_of(out['backend'])}）")
        say(f"耳朵模型：{out['asr_model']}")
    except Exception as e:  # noqa: BLE001
        say(f"（配置读不到：{e}）")
    out["ok"] = bool(out["py_ok"] and out["deps_ok"] and out["piper"] and out["piper_json"])
    _write_check(out)
    return 0


def cmd_venv() -> int:
    if os.path.exists(VENV_PY):
        say(f"✓ 已经有 .venv 了：{VENV_PY}")
        return 0
    base = sys.executable
    if os.path.normcase(base) == os.path.normcase(VENV_PY):
        base = os.environ.get("PYTHON", "python")
    say(f"建 .venv（用 {base}）…")
    r = subprocess.run([base, "-m", "venv", os.path.join(HERE, ".venv")])
    if r.returncode != 0 or not os.path.exists(VENV_PY):
        say("✗ 没建成。多半是这台机器上的 python 没装 venv 模块（python.org 的安装包默认带）")
        return 1
    say(f"✓ .venv 好了：{VENV_PY}")
    return 0


MIRRORS = {
    "tuna":   "https://pypi.tuna.tsinghua.edu.cn/simple",
    "aliyun": "https://mirrors.aliyun.com/pypi/simple",
    "ustc":   "https://mirrors.ustc.edu.cn/pypi/simple",
    "default": "",
}


def cmd_deps(mirror: str = "default") -> int:
    py = install_python()
    is_venv = os.path.normcase(py) == os.path.normcase(VENV_PY)
    if not is_venv:
        say("· 还没有 .venv，装进 PATH 里那个 python（想隔离就先跑 --venv）")
    if not os.path.exists(REQ):
        say(f"✗ 找不到 {REQ}")
        return 1
    say(f"装依赖进：{py}")
    idx = MIRRORS.get(mirror if mirror in MIRRORS else "default", "")
    if mirror and mirror not in MIRRORS:
        idx = mirror                      # 也接受直接给一个 URL
    if idx:
        say(f"下载源：{idx}")
    else:
        say("下载源：默认（pypi.org）。慢或者卡住就加 --mirror tuna")
    say("（numpy / faster-whisper / piper 这几个包不小，第一次几分钟）")
    # ★★ 这里**不做** `pip install --upgrade pip`（2026-10-26 实测教训）：
    #    在 Windows 上让 pip 升级它自己，会卡上半个多小时不动（我两个进程一起挂在那儿），
    #    而输出被我丢进了 DEVNULL —— 界面上就是「点了没反应」。
    #    venv 自带的那版 pip 装这些包够用，别多这一步。
    argv = [py, "-m", "pip", "install", "-r", REQ,
            "--disable-pip-version-check", "--no-input", "--progress-bar", "off",
            "--timeout", "30", "--retries", "3"]
    if idx:
        argv += ["-i", idx]
    t0 = time.time()
    r = subprocess.run(argv)
    if r.returncode != 0:
        say(f"✗ 没装完（退出码 {r.returncode}）。上面最后几行是原因；重跑会接着装。")
        if not idx:
            say("  国内网络建议换镜像重试：python bootstrap.py --deps --mirror tuna")
        return 1
    d = probe_deps(py)
    if not d["ok"]:
        say(f"✗ pip 说装完了，但还 import 不到：{', '.join(d['missing'])}")
        return 1
    if is_venv:
        try:
            with open(VENV_MARK, "w", encoding="utf-8") as f:
                f.write(time.strftime("%Y-%m-%d %H:%M:%S\n"))
        except Exception:  # noqa: BLE001
            pass
    say(f"✓ 依赖齐了（{time.time() - t0:.0f} 秒）")
    return 0


def _download(url: str, dest: str) -> None:
    tmp = dest + ".part"
    req = urllib.request.Request(url, headers={"User-Agent": "dafeiyu-setup"})
    with urllib.request.urlopen(req, timeout=60) as r, open(tmp, "wb") as f:
        total = int(r.headers.get("Content-Length") or 0)
        got = 0
        while True:
            b = r.read(1024 * 256)
            if not b:
                break
            f.write(b)
            got += len(b)
            if total:
                pct = got * 100 // total
                if pct % 20 == 0:
                    say(f"  …{pct}%（{got / 1048576:.0f}/{total / 1048576:.0f}MB）")
    os.replace(tmp, dest)


def cmd_piper() -> int:
    os.makedirs(PIPER_DIR, exist_ok=True)
    files = [("zh_CN-huayan-medium.onnx", PIPER_ONNX), ("zh_CN-huayan-medium.onnx.json", PIPER_JSON)]
    for name, dest in files:
        if os.path.exists(dest) and os.path.getsize(dest) > 1024:
            say(f"✓ 已经有了：{os.path.basename(dest)}")
            continue
        last = None
        for base in PIPER_URLS:
            try:
                say(f"下 {name} ← {base.split('/')[2]}")
                _download(base + name, dest)
                last = None
                break
            except Exception as e:  # noqa: BLE001
                last = e
                say(f"  这个源不行：{type(e).__name__}: {e}")
        if last is not None:
            say(f"✗ {name} 没下下来。可以手动下，放到 {PIPER_DIR}")
            return 1
        say(f"✓ {name}（{os.path.getsize(dest) / 1048576:.0f}MB）")
    say("✓ piper 音色齐了 —— 免费后端现在能出声")
    return 0


def cmd_whisper(size: str) -> int:
    py, _ = target_python()
    say(f"下耳朵模型 {size}（第一次几百 MB；下完缓存起来，以后不再下）")
    code = (
        "import sys\n"
        "from faster_whisper import WhisperModel\n"
        f"m = WhisperModel({size!r}, device='cpu', compute_type='int8')\n"
        "print('ok')\n"
    )
    r = subprocess.run([py, "-c", code])
    if r.returncode != 0:
        say("✗ 没下下来。检查网络；国内可以用 HF_ENDPOINT=https://hf-mirror.com 再跑一次")
        return 1
    say(f"✓ 耳朵模型 {size} 好了")
    return 0


def _kill_asr() -> None:
    """把在跑的常驻耳朵收掉（命令行里带 asr_server.py 的那个 python）。换模型才需要。"""
    ps = ("Get-CimInstance Win32_Process -Filter \"Name='python.exe'\" | "
          "Where-Object { $_.CommandLine -like '*asr_server.py*' } | "
          "ForEach-Object { Stop-Process -Id $_.ProcessId -Force; $_.ProcessId }")
    try:
        r = subprocess.run(["powershell", "-NoProfile", "-Command", ps],
                           capture_output=True, text=True, encoding="utf-8", errors="replace")
        say(f"收掉旧的耳朵：{r.stdout.strip() or '（没在跑）'}")
    except Exception as e:  # noqa: BLE001
        say(f"（收旧耳朵时出错：{e}）")
    time.sleep(1.0)


def _asr_call(restart: bool = False) -> int:
    """拉起常驻耳朵并回报它实际用的模型 / 设备。

    ★ 「常驻」的意思是：模型装上就一直待在显卡上，通话进程只跟它要文字。
      所以**换模型必须重启它**，否则 config 改了、耳朵里还是旧的（这就是 restart 那条路）。
    ⚠️ 小一号的引擎（仓库那份）没有 asr_server.py —— 那就没有耳朵进程，
      每通电话在心里加载一次。这种情况直接说清楚，别报错。
    """
    if not os.path.exists(os.path.join(HERE, "asr_server.py")):
        say("这台机器上的引擎没有「常驻耳朵」（没有 asr_server.py）—— 不用重启；"
            "每通电话它会自己加载模型，慢几秒而已。")
        return 0
    py, _ = target_python()
    if restart:
        _kill_asr()
    code = (
        "import json,sys\n"
        "sys.path.insert(0, r'%s')\n"
        "import asr\n"
        "ok = asr.ensure_asr(timeout=150.0)\n"
        "h = asr.asr_health() or {}\n"
        "print(json.dumps({'ok': bool(ok), 'health': h}, ensure_ascii=False))\n"
        % HERE
    )
    t0 = time.time()
    r = subprocess.run([py, "-c", code], capture_output=True, text=True,
                       encoding="utf-8", errors="replace", timeout=200)
    out = (r.stdout or "").strip()
    say(out or (r.stderr or "").strip())
    if r.returncode != 0:
        say("✗ 耳朵没起来（上面是原因；模型第一次要下载，慢一点算正常）")
        return 1
    say(f"✓ 耳朵在听（{time.time() - t0:.0f} 秒）")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--venv", action="store_true")
    ap.add_argument("--deps", action="store_true")
    ap.add_argument("--piper", action="store_true")
    ap.add_argument("--whisper", default=None)
    ap.add_argument("--asr", action="store_true")
    ap.add_argument("--asr-restart", action="store_true")
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--which", action="store_true")
    ap.add_argument("--mirror", default="default",
                    help="pip 下载源：default / tuna / aliyun / ustc，或者直接给一个 URL")
    a = ap.parse_args()

    if a.which:
        py, is_venv = target_python()
        print(json.dumps({"python": py, "venv": is_venv, "venv_py": VENV_PY,
                          "install_python": install_python(),
                          "venv_ready": os.path.exists(VENV_MARK),
                          "piper_onnx": PIPER_ONNX, "here": HERE}, ensure_ascii=False))
        return 0

    step = 0
    if a.check:
        return cmd_check()
    if a.all:
        step = cmd_venv()
        if step == 0:
            step = cmd_deps(a.mirror)
        if step == 0:
            step = cmd_piper()
        return step
    if a.venv:
        step = cmd_venv()
    if step == 0 and a.deps:
        step = cmd_deps(a.mirror)
    if step == 0 and a.piper:
        step = cmd_piper()
    if step == 0 and a.whisper:
        step = cmd_whisper(a.whisper)
    if step == 0 and a.asr:
        step = _asr_call(False)
    if step == 0 and a.asr_restart:
        step = _asr_call(True)
    if not any([a.check, a.venv, a.deps, a.piper, a.whisper, a.asr, a.asr_restart, a.all]):
        ap.print_help()
    return step


if __name__ == "__main__":
    raise SystemExit(main())
