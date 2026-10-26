# -*- coding: utf-8 -*-
"""通话设置：一个 JSON，三个入口（网页 / 桌宠 / 环回）共用。

为什么单独抽一个文件：他要求「音色来源」能当**选项**切，而不是改代码。
所以「用哪个 TTS」写在配置里，界面只改这个文件；进程启动时读一次。

★★ 这个文件也是**界面的单一真源**（2026-10-26 他要求把通话配置接进配置界面）。
   后端有几个、叫什么、花不花钱、每个后端有哪些参数、耳朵能选哪些模型 ——
   全部只写在**这里**，`setup-ui.ps1` 只负责把 `--json` 吐出来的东西画成控件。
   ⚠️ 别在 ps1 里再抄一份后端表：抄一次就多一个会说谎的地方（本项目已经栽过两次：
      台账和重启清单各写一份名单，结果桌宠漏了 17 小时）。

本地/云端花钱的事说清楚：
  · piper   —— 本机 ONNX，**完全免费**、离线、0 显存，音色偏播报腔
  · sovits  —— 本机 GPT-SoVITS，**完全免费**、克隆音色最像人，但吃显存、要单起一个常驻服务
  · cloud   —— SiliconFlow CosyVoice2，按量计费，**明显更自然**，首字节约 1.3s
  · openai  —— OpenAI 的 gpt-4o-mini-tts，最自然、还能给「语气指令」，但要 key + 走代理
"""
from __future__ import annotations

import json
import os
import sys

# 界面是拿「重定向到文件 + 按 UTF-8 读」的方式取 --json 的。
# 不设这一行的话，python 往管道里写中文会用系统代码页（这台是 936），界面读出来就是乱码。
for _s in (sys.stdout, sys.stderr):
    try:
        _s.reconfigure(encoding="utf-8", errors="replace")
    except Exception:  # noqa: BLE001
        pass

HERE = os.path.dirname(os.path.abspath(__file__))
STATE_DIR = os.path.normpath(os.path.join(HERE, "..", "..", "state", "call"))
CONFIG = os.path.join(STATE_DIR, "config.json")
_warned = False          # 「读不出来」只提示一次，别把日志刷满

# ★★ 能力自述（2026-10-26）：这份文件在**两个地方**跑 —— 他这台（有 sovits / 常驻耳朵 / 资源管家）
#    和别人从仓库下载的那份（引擎小一号，没这几样）。界面要按「这台机器实际有什么」来画，
#    不能照着一份写死的表画 —— 否则会让人去点一个这里根本没有的功能。
#    所以：**能力靠文件在不在判断**，表按能力裁。这样一个 config.py 在两棵树里内容完全相同，
#    不用再各维护一份（本项目栽过两次「同一个名单写两处」）。
_HAS_SOVITS = os.path.exists(os.path.join(HERE, "sovits_server.py"))
_HAS_ASR_SERVER = os.path.exists(os.path.join(HERE, "asr_server.py"))
_HAS_RES = os.path.exists(os.path.join(HERE, "res.py"))


# ---------------------------------------------------------------- 后端表
# 界面上的顺序 = 从免费到花钱。
# fields = 这个后端在界面上要露出哪几个可调参数（没列的参数照样生效，只是不露）。
#   kind: num（小数）· int（整数）· text（一行字）· choice（下拉，options 里挑）
#   w   : 列宽（逻辑像素，不给就 244）
#   hint: 给第一次用的人的一句解释 —— 界面会把它放在输入框下面
BACKENDS = [
    {
        "id": "piper", "label": "本地 piper（免费·离线）", "paid": False,
        "note": "不用网、不花钱、不占显存。音色像在念稿，胜在稳。第一次要下 63MB 音色模型。",
        "fields": [
            {"key": "length_scale", "label": "语速", "kind": "num", "min": 0.7, "max": 1.8, "step": 0.05,
             "hint": "越小越快。1.10 像随口说话，1.0 偏播报"},
            {"key": "noise_w_scale", "label": "起伏", "kind": "num", "min": 0.5, "max": 1.2, "step": 0.05,
             "hint": "越大语气越有高低，0.90 比较像人"},
        ],
    },
    {
        "id": "sovits", "label": "本地 GPT-SoVITS（免费·克隆音色）", "paid": False,
        "note": "克隆她自己的音色，最像人。要本机另外装好 GPT-SoVITS，占约 1.3G 显存，第一句要多等二十几秒（它在启动）。",
        "fields": [
            {"key": "port", "label": "服务端口", "kind": "int", "w": 110,
             "hint": "默认 9880"},
            {"key": "speed", "label": "语速", "kind": "num", "min": 0.7, "max": 1.5, "step": 0.05,
             "hint": "1.0 是原速"},
        ],
    },
    {
        "id": "cloud", "label": "云端 CosyVoice2（按量计费）", "paid": True,
        "note": "硅基流动的 CosyVoice2，明显更自然，首字节约 1.3 秒。按字数计费，要一把硅基流动 key。",
        "fields": [
            {"key": "voice", "label": "音色", "kind": "text",
             "hint": "硅基流动的音色名；默认 FunAudioLLM/CosyVoice2-0.5B:anna（女声）"},
            {"key": "speed", "label": "语速", "kind": "num", "min": 0.7, "max": 1.5, "step": 0.05, "hint": "1.0 是原速"},
        ],
    },
    {
        "id": "openai", "label": "OpenAI TTS（需要 key·走代理）", "paid": True,
        "note": "最自然，还能给「语气指令」。要 OpenAI 的 key，本机得能连上 api.openai.com。",
        "fields": [
            {"key": "model", "label": "模型", "kind": "choice", "options": [
                ["gpt-4o-mini-tts", "gpt-4o-mini-tts（能听话术指令）"],
                ["tts-1", "tts-1（便宜、快）"],
                ["tts-1-hd", "tts-1-hd（音质好、贵）"]]},
            {"key": "voice", "label": "音色", "kind": "choice", "options": [
                ["nova", "nova（女声·默认）"], ["shimmer", "shimmer（女声·更软）"],
                ["coral", "coral（女声·活泼）"], ["sage", "sage（女声·冷静）"],
                ["alloy", "alloy"], ["echo", "echo"], ["fable", "fable"],
                ["onyx", "onyx（男声·低）"], ["ash", "ash"], ["ballad", "ballad"], ["verse", "verse"]]},
            {"key": "base_url", "label": "接口地址", "kind": "text",
             "hint": "默认官方地址；用中转就改成中转的"},
        ],
    },
]

# 这台机器没有 sovits 服务端脚本 ⇒ 这个选项根本不露（别让人去点一个不存在的功能）。
if not _HAS_SOVITS:
    BACKENDS = [b for b in BACKENDS if b["id"] != "sovits"]

# ---------------------------------------------------------------- 耳朵（ASR）
# faster-whisper 的模型档位。**中文只列不带 .en 的**（.en 只认英文）。
ASR_MODELS = [
    {"id": "tiny",     "label": "tiny · 最快最省",  "note": "约 75MB，糙，口音重就听不懂"},
    {"id": "base",     "label": "base · 省",       "note": "约 145MB，能用，长句偶尔丢字"},
    {"id": "small",    "label": "small · 平衡（默认）", "note": "约 480MB，中文日常够用"},
    {"id": "medium",   "label": "medium · 准",     "note": "约 1.5GB，显存吃 2~3G，慢一点"},
    {"id": "large-v3", "label": "large-v3 · 最准", "note": "约 3GB，显存吃 4~5G，第一句明显慢"},
]

# w = 这一列多宽（数字是逻辑像素）。不给就 244 —— 四个参数要塞进一行，所以窄的那几个写死。
ASR_FIELDS = [
    {"key": "model", "label": "模型", "kind": "choice", "w": 210,
     "options": [[m["id"], m["label"]] for m in ASR_MODELS]},
    {"key": "device", "label": "算在哪", "kind": "choice", "w": 210, "options": [
        ["", "自动（有 N 卡就用 N 卡）"], ["cuda", "显卡"], ["cpu", "CPU"]],
     "hint": "自动就行；显卡被别的东西占满时才手动挑 CPU"},
    {"key": "compute", "label": "精度", "kind": "choice", "w": 170, "options": [
        ["", "自动"], ["float16", "float16 · 省显存"],
        ["int8_float16", "int8_float16 · 更省"], ["int8", "int8 · CPU 用"]]},
]
# 端口只有「常驻耳朵」那种架构才需要（那是一个独立服务）。
if _HAS_ASR_SERVER:
    ASR_FIELDS.append({"key": "port", "label": "耳朵端口", "kind": "int", "w": 110, "hint": "默认 9890"})

CALL_FIELDS = [
    {"key": "silence_end", "label": "多静算你说完", "kind": "num", "min": 0.4, "max": 2.0, "step": 0.05,
     "hint": "秒。0.90 比较自然；太小会抢话，太大要等"},
    {"key": "max_reply_chars", "label": "一句最多几个字", "kind": "int", "min": 10, "max": 80,
     "hint": "电话里长了没人听完"},
]
# 「通话时让壁纸退场」要 res.py（资源管家）在才有意义。
if _HAS_RES:
    CALL_FIELDS.append(
        {"key": "yield_wallpaper", "label": "通话时让动态壁纸退场", "kind": "choice", "options": [
            ["true", "让（挂断自动还回来）"], ["false", "不让"]],
         "hint": "通话卡多半是核显的画面管线被壁纸压满，不是算力"})

DEFAULTS = {
    "tts": {
        "backend": "piper",
        "piper": {"length_scale": 1.10, "noise_scale": 0.72, "noise_w_scale": 0.90},
        # GPT-SoVITS 是**另一个常驻进程**（sovits_server.py），这里只记怎么连上它。
        # 参考音 / 参考文本在服务端那边（--ref / --prompt），换音色 = 重启那个服务。
        "sovits": {"host": "127.0.0.1", "port": 9880, "speed": 1.0},
        "cloud": {"voice": "FunAudioLLM/CosyVoice2-0.5B:anna", "speed": 1.0},
        "openai": {"model": "gpt-4o-mini-tts", "voice": "nova", "base_url": "https://api.openai.com/v1"},
    },
    # 耳朵也是一个**常驻进程**（asr_server.py）：模型装上就一直待在显卡上，
    # 不用每通电话重装一遍（实测 2.62s）。这里只记怎么连上它。
    "asr": {"model": "small", "device": None, "compute": None,
            "host": "127.0.0.1", "port": 9890},
    # yield_wallpaper：通话期间让动态壁纸先退场，挂断自动还回去。
    # ★ 为什么：2026-10-26 19:4x 他说「CPU 没有占用，而是 GPU0 有 100% 的占用」——
    #   实测卡的是**画面输出这条管线**：wallpaper64 的 videodecode 81.8% + videoprocessing 52.1%、
    #   dwm 3d 60.7%，而 5080 是 0%/4.3W。它不是我们的进程，但通话时让它让位、挂断还回去，
    #   才是「把资源放到合理的位置」而不是「关掉」。
    "call": {"silence_end": 0.90, "max_reply_chars": 25, "yield_wallpaper": True},
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
    """读配置。

    ★★ 2026-10-26 19:3x 挖出来的**真·bug**：这个文件有两个写者 —— python 这边（无 BOM）
    和 `call.ps1` 的音色按钮（`Set-Content -Encoding UTF8`，**带 UTF-8 BOM**）。
    `json.load(encoding="utf-8")` 遇到 BOM 会抛 `Expecting value: line 1 column 1`，
    而旧写法把这个异常吞了、直接退回 DEFAULTS（backend = piper）——
    于是**他在窗口里点音色、点一次换一次，听到的永远是 piper**，
    看起来就像「切换音色有 bug、声音没有变化」。文件里明明写着 `cloud`，python 读出来却是 `piper`。
    ⇒ 读一律用 `utf-8-sig`（有无 BOM 都吃得下）；读失败要**说出来**，不许静默兜底。
    """
    global _warned
    try:
        with open(CONFIG, "r", encoding="utf-8-sig") as f:
            return _merge(DEFAULTS, json.load(f))
    except FileNotFoundError:
        return json.loads(json.dumps(DEFAULTS))
    except Exception as e:  # noqa: BLE001
        if not _warned:
            _warned = True
            print(f"[config] 配置读不出来，先用默认值（backend=piper）："
                  f"{type(e).__name__}: {e}", flush=True)
        return json.loads(json.dumps(DEFAULTS))


def save(cfg: dict) -> str:
    """★ 一律**不带 BOM** 写（`encoding="utf-8"`）。带 BOM 的那次事故见 load() 的注释。"""
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


# ---------------------------------------------------------------- 界面要的那一份
def _dotted(cfg: dict, path: str, default=None):
    cur = cfg
    for part in path.split("."):
        if not isinstance(cur, dict) or part not in cur:
            return default
        cur = cur[part]
    return cur


def _put_dotted(cfg: dict, path: str, value) -> None:
    parts = path.split(".")
    cur = cfg
    for part in parts[:-1]:
        nxt = cur.get(part)
        if not isinstance(nxt, dict):
            nxt = {}
            cur[part] = nxt
        cur = nxt
    cur[parts[-1]] = value


def _coerce(raw: str):
    """命令行 / 界面传进来的都是字符串 —— 尽量还原成它本来的类型。
    `true`→True · `null`→None · `9880`→9880 · `1.10`→1.1 · 其它保持字符串。"""
    try:
        return json.loads(raw)
    except Exception:  # noqa: BLE001
        return raw


def _as_bool(v):
    if isinstance(v, str):
        return v.strip().lower() in ("1", "true", "yes", "on")
    return bool(v)


# 界面「保存」时该写成什么类型（别的键按 json 字面量还原）
_BOOL_KEYS = {"call.yield_wallpaper"}
_INT_KEYS = {"asr.port", "tts.sovits.port", "call.max_reply_chars"}


def set_many(pairs: list[tuple[str, str]]) -> dict:
    """按 `a.b=c` 批量改，一次落盘。界面「保存」就调这个。

    ⚠️ 只改点出来的那几个键，**其余原样保留** —— 配置是他在窗口里点出来的，
    别因为界面不认识某个键就把它抹掉（界面永远比配置旧）。
    """
    cfg = load()
    for path, raw in pairs:
        path = path.strip()
        if not path:
            continue
        if path == "tts.backend":
            ids = [b["id"] for b in BACKENDS]
            if raw not in ids:
                raise SystemExit(f"没有这个音色来源：{raw}（可选：{', '.join(ids)}）")
            _put_dotted(cfg, path, raw)
            continue
        if path in _BOOL_KEYS:
            _put_dotted(cfg, path, _as_bool(raw))
        elif path in _INT_KEYS:
            _put_dotted(cfg, path, int(float(raw)))
        else:
            val = _coerce(raw)
            # 耳朵的 device/compute：空字符串 = 自动 = None
            if path in ("asr.device", "asr.compute") and val in ("", None):
                val = None
            _put_dotted(cfg, path, val)
    save(cfg)
    return cfg


def snapshot() -> dict:
    """`--json` 的全部内容：界面画控件要的都在这一份里。

    ★ 界面**不许**自己写死后端名 / 模型名 / 参数名 —— 都从这里读。
      于是「引擎里还没有 sovits」的那份老代码，吐出来的就是三个后端，
      界面照三个画，不会指着一个不存在的功能让人点。
    """
    cfg = load()
    return {
        "ok": True,
        "config": cfg,
        "backend": backend(cfg),
        "backends": BACKENDS,
        "asr_models": ASR_MODELS,
        "asr_fields": ASR_FIELDS,
        "call_fields": CALL_FIELDS,
        "paths": {"config": CONFIG, "state": STATE_DIR, "here": HERE},
        # 能力自述：界面靠这几个布尔决定要不要画「重启耳朵」「让壁纸退场」这类按钮
        "caps": {
            "sovits": any(b["id"] == "sovits" for b in BACKENDS),
            "asr_server": os.path.exists(os.path.join(HERE, "asr_server.py")),
            "res": os.path.exists(os.path.join(HERE, "res.py")),
            "voice_test": os.path.exists(os.path.join(HERE, "voice-test.py")),
            "bootstrap": os.path.exists(os.path.join(HERE, "bootstrap.py")),
        },
    }


def main() -> int:
    """命令行：
        python config.py                看现在的
        python config.py piper          切成某个音色来源
        python config.py --list         有哪些后端
        python config.py --json         给界面看的整份（含字段表）
        python config.py --set tts.backend=sovits asr.model=medium
    """
    import sys
    args = sys.argv[1:]
    if args and args[0] == "--json":
        print(json.dumps(snapshot(), ensure_ascii=False))
        return 0
    if args and args[0] == "--set":
        pairs = []
        for a in args[1:]:
            if "=" not in a:
                raise SystemExit(f"要写成 key=value：{a}")
            k, v = a.split("=", 1)
            pairs.append((k, v))
        cfg = set_many(pairs)
        be = backend(cfg)
        print(json.dumps({"ok": True, "saved": dict(pairs), "path": CONFIG,
                          "backend": be, "label": label_of(be)}, ensure_ascii=False))
        return 0
    if args and args[0] == "--list":
        for b in BACKENDS:
            tag = "（花钱）" if b["paid"] else "（免费）"
            print(f"{b['id']:8s} {b['label']}{tag}")
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
