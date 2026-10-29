# -*- coding: utf-8 -*-
"""唱歌：把一段别人的清唱**换成你的音色**（零样本音色转换，不用训练）。

怎么做到的（一句话）：**旋律和气口都是原唱的，只有音色是换的。**
这条链路本身不做「唱歌」——它做的是 *voice conversion*（SVC）。
所以：

  · 气口、换气、咬字的位置来自**原始唱段**，不是模型编的 → 听着才像真人在唱；
  · 普通说话 TTS 直接拿去唱会电音走音，那是两回事；
  · 修音修猛了就是网上的「电音」——所以这里默认不动音高，需要时只整段移调。

底层用 **Seed-VC**（https://github.com/Plachtaa/seed-vc），本文件只负责
「找模型 / 拼参数 / 跑它 / 把结果转成能发出去的格式」，不复制它的代码。

## 用法

```bash
# 自检：环境、权重、显卡
python sing.py --check

# 唱一首（源音=别人的清唱，参考音=你的干净人声）
python sing.py --source 原唱.wav --reference 我的声音.wav --out 输出.mp3

# 整段升 2 个半音（不改变速度）
python sing.py --source 原唱.wav --semitones 2
```

首次跑之前需要：

1. `git clone https://github.com/Plachtaa/seed-vc`，路径写进 `sing.seedvc_root`；
2. 一个装了 torch + 它那套依赖的 Python，路径写进 `sing.python`（**别装进正在跑 TTS 的环境**）；
3. `python sing.py --apply-patches` —— 给 Seed-VC 打两个小补丁（见下面「两个必须打的补丁」）。

配置读 `state/config.json` 的 `sing` 段（跟通话设置同一个文件，界面改它即可）。

## 两个必须打的补丁（`--apply-patches` 自动做，幂等）

**① 别让它去 HuggingFace 原站找权重。**
国内直连 `huggingface.co` 经常握手超时；`hf-mirror.com` 虽能下，但它的 `/resolve/` 返回 302
**不带 `X-Repo-Commit`**，`huggingface_hub` 会直接抛
`FileMetadataError: Distant resource does not seem to be on huggingface.co`。
⇒ 本文件把 `hf_utils.py` 换成「本地 `./checkpoints/<文件名>` 优先、找不到再走 Hub」的版本，
并且可选的把 `inference.py` 里的 whisper / bigvgan 也指向本地目录。
权重用 `curl -L` 自己下到 `checkpoints/` 即可。

**② `torchaudio.save()` 在新版 torchaudio 上要 torchcodec。**
torchaudio ≥ 2.9 把保存交给 `torchcodec`，没装就 `ImportError: TorchCodec is required`。
⇒ 把那一行换成 `soundfile.write()`。
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))

# 权重清单：名字 -> (repo, 文件名)，下载地址 = https://hf-mirror.com/<repo>/resolve/main/<文件名>
WEIGHTS = [
    ("seedvc_dit_f0", "Plachta/Seed-VC", "DiT_seed_v2_uvit_whisper_base_f0_44k_bigvgan_pruned_ft_ema_v2.pth"),
    ("seedvc_dit_cfg", "Plachta/Seed-VC", "config_dit_mel_seed_uvit_whisper_base_f0_44k.yml"),
    ("rmvpe", "lj1995/VoiceConversionWebUI", "rmvpe.pt"),
    ("campplus", "funasr/campplus", "campplus_cn_common.bin"),
]

DEFAULTS = {
    "seedvc_root": "",
    "python": "python",
    "reference": "",
    "steps": 30,
    "cfg_rate": 0.7,
    "semitones": 0,
    "auto_f0_adjust": False,
    "fp16": True,
    "hf_endpoint": "https://hf-mirror.com",
    "ffmpeg": "ffmpeg",
    "out_dir": "",
}


# ---------------------------------------------------------------- 配置

def _state_dir() -> str:
    """设置放哪：跟通话共用一份 config.json。几种常见摆放都认。
       ① <这里>/state            —— 独立克隆出来单独用
       ② <这里>/call/state       —— 和 call 平级
       ③ <这里>/../../state/call —— 塞进桌宠项目里的那种布局
    """
    for cand in (os.path.join(HERE, "state"),
                 os.path.join(HERE, "call", "state"),
                 os.path.abspath(os.path.join(HERE, "..", "..", "state", "call"))):
        if os.path.isdir(cand):
            return cand
    return os.path.join(HERE, "state")


def load_cfg() -> dict:
    """设置存在两处，后者盖前者：
       ① state/config.json 的 `sing` 段（跟通话共用一份文件时用）
       ② state/sing.json 整份（独立用，GUI 写的是这个）
    """
    cfg = dict(DEFAULTS)
    sd = _state_dir()
    for path, key in ((os.path.join(sd, "config.json"), "sing"), (os.path.join(sd, "sing.json"), None)):
        try:
            with open(path, "r", encoding="utf-8") as f:
                data = json.load(f)
            cfg.update((data.get(key) if key else data) or {})
        except Exception:  # noqa: BLE001
            pass
    return cfg


def save_cfg(patch: dict) -> str:
    sd = _state_dir()
    os.makedirs(sd, exist_ok=True)
    path = os.path.join(sd, "sing.json")
    cur = {}
    try:
        with open(path, "r", encoding="utf-8") as f:
            cur = json.load(f) or {}
    except Exception:  # noqa: BLE001
        cur = {}
    cur.update(patch)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(cur, f, ensure_ascii=False, indent=2)
    return path


def _abs(p: str) -> str:
    if not p:
        return ""
    return p if os.path.isabs(p) else os.path.abspath(os.path.join(HERE, p))


# ---------------------------------------------------------------- 小工具

def run(cmd, cwd=None, env=None, timeout=None) -> tuple[int, str]:
    p = subprocess.run(
        cmd, cwd=cwd, env=env, timeout=timeout,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True, encoding="utf-8", errors="replace",
    )
    return p.returncode, p.stdout or ""


def log(msg: str) -> None:
    print(msg, flush=True)


# ---------------------------------------------------------------- 补丁

HF_UTILS = '''import os
from huggingface_hub import hf_hub_download

# 本地优先：hf-mirror 的 /resolve/ 302 不带 X-Repo-Commit，huggingface_hub 会抛
# FileMetadataError。用 curl 把文件下到 ./checkpoints 后，这里直接用它。
LOCAL_DIR = os.environ.get("SEEDVC_LOCAL_DIR", "./checkpoints")


def _local(name):
    for p in (os.path.join(LOCAL_DIR, name), os.path.join(LOCAL_DIR, os.path.basename(name))):
        if os.path.isfile(p) and os.path.getsize(p) > 0:
            return p
    return None


def load_custom_model_from_hf(repo_id, model_filename="pytorch_model.bin", config_filename=None):
    os.makedirs("./checkpoints", exist_ok=True)
    model_path = _local(model_filename) or hf_hub_download(
        repo_id=repo_id, filename=model_filename, cache_dir="./checkpoints"
    )
    if config_filename is None:
        return model_path
    config_path = _local(config_filename) or hf_hub_download(
        repo_id=repo_id, filename=config_filename, cache_dir="./checkpoints"
    )
    return model_path, config_path
'''

LOCAL_DIR_HELPER = '''
def _local_model_dir(name):
    """优先用 curl 下到 ./checkpoints/<repo 名>/ 的组件，而不是去 Hub 上找。"""
    cand = os.path.join("./checkpoints", name.split("/")[-1])
    if os.path.isdir(cand) and os.path.isfile(os.path.join(cand, "config.json")):
        return cand
    return name

'''


def apply_patches(root: str) -> list[str]:
    done = []
    hf = os.path.join(root, "hf_utils.py")
    inf = os.path.join(root, "inference.py")
    if not os.path.isfile(inf):
        raise SystemExit(f"这里不像 Seed-VC 的根目录（没找到 inference.py）：{root}")

    # ① hf_utils.py —— 整个换掉（它只有十几行，替换比正则安全）
    if os.path.isfile(hf):
        with open(hf, "r", encoding="utf-8") as f:
            cur = f.read()
        if "SEEDVC_LOCAL_DIR" in cur:
            done.append("hf_utils.py · 已经是本地优先版，跳过")
        else:
            shutil.copy2(hf, hf + ".bak")
            with open(hf, "w", encoding="utf-8") as f:
                f.write(HF_UTILS)
            done.append("hf_utils.py · 换成「本地 ./checkpoints 优先」")

    with open(inf, "r", encoding="utf-8") as f:
        src = f.read()
    orig = src

    # ② torchaudio.save(...) -> soundfile
    if "TorchCodec" in src or "soundfile as _sf" in src:
        done.append("inference.py · 保存已经不是 torchaudio，跳过")
    else:
        pat = re.compile(r"^([ \t]*)torchaudio\.save\((.*)\)[ \t]*$", re.M)
        m = pat.search(src)
        if not m:
            done.append("inference.py · 没找到 torchaudio.save 那一行，跳过了（新版 Seed-VC 可能改了写法）")
        else:
            ind = m.group(1)
            repl = (
                f"{ind}# torchaudio>=2.9 的 save() 交给 torchcodec，没装就 ImportError；改用 soundfile。\n"
                f"{ind}import soundfile as _sf\n"
                f"{ind}_out_path = os.path.join(args.output, "
                f"f\"vc_{{source_name}}_{{target_name}}_{{length_adjust}}_{{diffusion_steps}}_"
                f"{{inference_cfg_rate}}.wav\")\n"
                f"{ind}_sf.write(_out_path, vc_wave.cpu().numpy().reshape(-1), sr)\n"
                f"{ind}print(\"WROTE \" + _out_path, flush=True)\n"
            )
            src = src[: m.start()] + repl + src[m.end():]
            done.append("inference.py · torchaudio.save → soundfile.write")

    # ③ whisper / bigvgan 走本地目录
    if "_local_model_dir(" in src:
        done.append("inference.py · whisper/bigvgan 已是本地优先，跳过")
    else:
        anchor = "from hf_utils import load_custom_model_from_hf\n"
        if anchor in src:
            src = src.replace(anchor, anchor + LOCAL_DIR_HELPER, 1)
            src = src.replace(
                "bigvgan_name = model_params.vocoder.name",
                "bigvgan_name = _local_model_dir(model_params.vocoder.name)", 1)
            src = src.replace(
                "whisper_name = model_params.speech_tokenizer.name",
                "whisper_name = _local_model_dir(model_params.speech_tokenizer.name)", 1)
            done.append("inference.py · whisper / bigvgan 指向本地 checkpoints/<名>/")
        else:
            done.append("inference.py · 没找到 hf_utils 的 import，跳过了本地目录那条")

    if src != orig:
        shutil.copy2(inf, inf + ".bak")
        with open(inf, "w", encoding="utf-8") as f:
            f.write(src)
    return done


# ---------------------------------------------------------------- 自检

def check(cfg: dict) -> dict:
    root = _abs(cfg["seedvc_root"])
    py = cfg["python"]
    out = {"seedvc_root": root, "python": py, "problems": []}

    if not root or not os.path.isfile(os.path.join(root, "inference.py")):
        out["problems"].append("seedvc_root 不对：那儿没有 inference.py")
    else:
        ck = os.path.join(root, "checkpoints")
        have = []
        for _, repo, name in WEIGHTS:
            p = os.path.join(ck, name)
            have.append({"name": name, "ok": os.path.isfile(p) and os.path.getsize(p) > 1000,
                         "mb": round(os.path.getsize(p) / 1e6, 1) if os.path.isfile(p) else 0,
                         "url": f"{cfg['hf_endpoint'].rstrip('/')}/{repo}/resolve/main/{name}"})
        out["weights"] = have
        for w in have:
            if not w["ok"]:
                out["problems"].append(f"缺权重 {w['name']}")
        out["patched"] = ("SEEDVC_LOCAL_DIR" in open(os.path.join(root, "hf_utils.py"), encoding="utf-8").read()
                          if os.path.isfile(os.path.join(root, "hf_utils.py")) else False)
    try:
        rc, txt = run([py, "-c", "import torch;print(torch.__version__, torch.cuda.is_available(), "
                                  "(torch.cuda.get_device_name(0) if torch.cuda.is_available() else '-'))"], timeout=120)
        out["torch"] = txt.strip() if rc == 0 else f"失败：{txt.strip()[:200]}"
        if rc != 0:
            out["problems"].append("python 跑不起来 / 没装 torch")
        elif " True " not in out["torch"]:
            out["problems"].append("torch 看不到显卡（会退到 CPU，非常慢）")
    except Exception as e:  # noqa: BLE001
        out["torch"] = f"失败：{e}"
        out["problems"].append("python 起不来")

    ref = _abs(cfg["reference"])
    out["reference"] = ref
    if not ref or not os.path.isfile(ref):
        out["problems"].append("没有可用的参考音色（sing.reference）")
    return out


# ---------------------------------------------------------------- 主流程

def main() -> int:
    ap = argparse.ArgumentParser(description="用 Seed-VC 把一段唱换成你的音色")
    ap.add_argument("--source", help="源音频：别人的清唱 / 有人声的歌")
    ap.add_argument("--reference", help="参考音色：你的干净人声（10~25 秒最佳）")
    ap.add_argument("--out", help="输出路径（.wav 或 .mp3）")
    ap.add_argument("--steps", type=int, help="扩散步数，默认 30；降到 12~16 更快、质量略降")
    ap.add_argument("--cfg-rate", type=float, help="引导强度，默认 0.7")
    ap.add_argument("--semitones", type=int, help="整段移调（半音），0 = 不动")
    ap.add_argument("--auto-f0-adjust", action="store_true", help="把旋律整体塞进参考音色的音域")
    ap.add_argument("--no-f0", action="store_true", help="关掉 f0 条件（几乎总是要开着）")
    ap.add_argument("--check", action="store_true", help="只自检，不转换")
    ap.add_argument("--apply-patches", action="store_true", help="给 Seed-VC 打那两个补丁")
    ap.add_argument("--json", action="store_true", help="把结果打成 JSON")
    ap.add_argument("--get", action="store_true", help="把当前设置打成 JSON（给界面读）")
    ap.add_argument("--set", metavar="K=V", nargs="+", help="存设置，例如 --set steps=24 semitones=2")
    args = ap.parse_args()

    cfg = load_cfg()
    root = _abs(cfg["seedvc_root"])

    if args.set:
        patch = {}
        for item in args.set:
            if "=" not in item:
                raise SystemExit(f"--set 要 K=V 的形式：{item}")
            k, v = item.split("=", 1)
            k = k.strip()
            if k not in DEFAULTS:
                raise SystemExit(f"不认识的设置项：{k}（可用：{', '.join(DEFAULTS)}）")
            if isinstance(DEFAULTS[k], bool):
                v = v.strip().lower() in ("1", "true", "yes", "on")
            elif isinstance(DEFAULTS[k], int):
                v = int(v)
            elif isinstance(DEFAULTS[k], float):
                v = float(v)
            patch[k] = v
        log(save_cfg(patch))
        return 0

    if args.get:
        log(json.dumps(load_cfg(), ensure_ascii=False, indent=2))
        return 0

    if args.apply_patches:
        if not root:
            raise SystemExit("先把 sing.seedvc_root 设成 Seed-VC 的目录")
        for line in apply_patches(root):
            log("· " + line)
        return 0

    if args.check:
        info = check(cfg)
        log(json.dumps(info, ensure_ascii=False, indent=2))
        return 0 if not info["problems"] else 2

    if not args.source:
        ap.error("要么 --check / --apply-patches，要么给 --source")

    src = _abs(args.source)
    if not os.path.isfile(src):
        raise SystemExit(f"源音频不存在：{src}")
    ref = _abs(args.reference or cfg["reference"])
    if not os.path.isfile(ref):
        raise SystemExit(f"参考音色不存在：{ref}")
    if not root:
        raise SystemExit("sing.seedvc_root 没设")

    steps = args.steps or int(cfg["steps"])
    cfg_rate = args.cfg_rate if args.cfg_rate is not None else float(cfg["cfg_rate"])
    semis = args.semitones if args.semitones is not None else int(cfg["semitones"])
    f0 = not args.no_f0
    auto = bool(args.auto_f0_adjust or cfg.get("auto_f0_adjust"))

    out_dir = tempfile.mkdtemp(prefix="sing-")
    ck = os.path.join(root, "checkpoints")
    ckpt = os.path.join(ck, WEIGHTS[0][2])
    conf = os.path.join(ck, WEIGHTS[1][2])

    cmd = [
        cfg["python"], "inference.py",
        "--source", src, "--target", ref, "--output", out_dir,
        "--diffusion-steps", str(steps),
        "--inference-cfg-rate", str(cfg_rate),
        "--f0-condition", "True" if f0 else "False",
        "--semi-tone-shift", str(semis),
        "--auto-f0-adjust", "True" if auto else "False",
        "--fp16", "True" if cfg["fp16"] else "False",
    ]
    # 本地已经有整份权重就直接指过去，省掉一次「去 Hub 上问一遍」
    if os.path.isfile(ckpt) and os.path.isfile(conf):
        cmd += ["--checkpoint", ckpt, "--config", conf]

    env = dict(os.environ)
    if cfg.get("hf_endpoint"):
        env["HF_ENDPOINT"] = cfg["hf_endpoint"]
    env.setdefault("PYTHONIOENCODING", "utf-8")

    t0 = time.time()
    log(f"跑 Seed-VC …（{os.path.basename(src)} → {os.path.basename(ref)}，{steps} 步）")
    rc, txt = run(cmd, cwd=root, env=env)
    if rc != 0:
        tail = "\n".join(txt.strip().splitlines()[-25:])
        raise SystemExit(f"Seed-VC 失败（退出码 {rc}）：\n{tail}")

    made = [os.path.join(out_dir, f) for f in os.listdir(out_dir) if f.lower().endswith(".wav")]
    if not made:
        raise SystemExit("跑完了但没有产出 wav：\n" + "\n".join(txt.strip().splitlines()[-15:]))
    wav = max(made, key=os.path.getsize)

    out = _abs(args.out) if args.out else os.path.join(
        _abs(cfg.get("out_dir") or ".") or HERE, os.path.splitext(os.path.basename(src))[0] + "-sung.wav")
    os.makedirs(os.path.dirname(out) or ".", exist_ok=True)

    final = wav
    if out.lower().endswith(".mp3"):
        ff = cfg.get("ffmpeg") or "ffmpeg"
        rc, txt = run([ff, "-hide_banner", "-loglevel", "error", "-y", "-i", wav,
                       "-af", "volume=-1.5dB", "-ac", "1", "-ar", "44100",
                       "-c:a", "libmp3lame", "-b:a", "160k", out])
        if rc != 0:
            raise SystemExit(f"ffmpeg 转 mp3 失败：\n{txt[-800:]}")
        final = out
    else:
        shutil.copyfile(wav, out)
        final = out

    secs = round(time.time() - t0, 1)
    log(f"好了 · {final} · {secs}s")
    if args.json:
        log(json.dumps({"ok": True, "out": final, "seconds": secs, "steps": steps,
                        "semitones": semis, "source": src, "reference": ref}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
