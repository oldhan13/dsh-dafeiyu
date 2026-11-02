# -*- coding: utf-8 -*-
"""让绮萱（DiffSinger 声库）把我给的词唱出来 —— 走 OpenUtau 本体的渲染管线。

为什么不用手搓 onnx：那套出来的 mel 是噪点（帧间不相关），OpenUtau 自己的管线才是对的
（差别在首尾补帧、variance 产出的 breathiness/voicing、先跑 dsdur 取真实时长）。

★ 好听的那一层（2026-11-02 加）：
  ① 句间留空 + 句首换气（合成的吸气噪声，放在空里）
  ② 音符自带颤音（OpenUtau 原生 vibrato，落在音高上，不是加料）
  ③ 混响（两条去相关的 IR，左右不同，带早期反射与高频衰减）
  ④ 一点点气声（高通后的自身，很轻）
  → 每句单独渲染（每句一个 wav，时间原点 = 首音 tick − 92.9ms），
    再按 tick 精确拼回时间轴。为什么每句单渲：一个工程里带空时会出多个
    cache wav，靠文件名哈希分不清哪句是哪句。

用法（用 svc-venv 的 python）：
    python sing_svs.py --lyrics "睡吧，今天的风不用管。" --out out.mp3
    python sing_svs.py --lyrics "..." --notes 62,64,66 --tempo 90 --out out.mp3
    python sing_svs.py --lyrics "..." --out out.mp3 --her        # 再过 Seed-VC 换我的音色
    python sing_svs.py --lyrics "..." --out out.mp3 --verify     # 跑无提示 ASR 打分
    python sing_svs.py --lyrics "..." --out out.mp3 --dry        # 关掉好听那层（对照）

输出：wav/mp3，--json 时吐一行 JSON。
"""
import argparse
import glob
import json
import os
import shutil
import subprocess
import sys
import time

import numpy as np
import soundfile as sf

try:                                    # 控制台是 GBK 时，别让中文/异体字直接炸掉
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

HERE = os.path.dirname(os.path.abspath(__file__))
SING_PY = os.path.join(HERE, "sing.py")

# 配置的唯一真源是 config.py（界面、命令行、这里都读它）。
try:
    import config as _cfgmod
except Exception:                        # noqa: BLE001 —— 单独拷走这个脚本时也得能跑
    _cfgmod = None


def _svs_cfg():
    if _cfgmod is None:
        return {}
    try:
        return (_cfgmod.load() or {}).get("svs", {}) or {}
    except Exception:                    # noqa: BLE001
        return {}


def _sing_cfg():
    """sing.json：参考音色 + seed-vc 的位置（`sing.py --check` 用的同一份）"""
    try:
        with open(os.path.join(os.path.dirname(HERE), "..", "state", "call", "sing.json"),
                  "r", encoding="utf-8-sig") as f:
            return json.load(f)
    except Exception:                    # noqa: BLE001
        return {}


_CFG = _svs_cfg()
_SING = _sing_cfg()


def _find_openutau():
    for cand in (_CFG.get("openutau_dir"), os.environ.get("DSH_OPENUTAU"),
                 os.path.join(os.path.expanduser("~"), "dsh-tools", "openutau"),
                 os.path.join(os.path.expanduser("~"), "OpenUtau")):
        if cand and os.path.exists(os.path.join(cand, "OpenUtau.exe")):
            return os.path.abspath(cand)
    return ""


def _find_singer(ou_dir):
    want = (_CFG.get("singer") or "").strip()
    root = os.path.join(ou_dir, "Singers") if ou_dir else ""
    if want and os.path.isdir(os.path.join(root, want)):
        return want
    if root and os.path.isdir(root):
        for name in sorted(os.listdir(root)):
            if os.path.exists(os.path.join(root, name, "dsconfig.yaml")):
                return name
    return want or ""


OU_DIR = _find_openutau()
OU_EXE = os.path.join(OU_DIR, "OpenUtau.exe") if OU_DIR else ""
SINGER = _find_singer(OU_DIR)
PROJ_DIR = os.path.join(OU_DIR, "projects") if OU_DIR else os.path.join(HERE, "svs-projects")
PY = _SING.get("python") or sys.executable
REF_VOICE_CFG = _SING.get("reference") or ""

BPM_DEFAULT = int(_CFG.get("tempo") or 90)
GLIDE_SCALE = float(_CFG.get("glide", 100)) / 100.0     # 0 = 全都不滑，1 = 按跨度抽签
RES = 480
NOTE_TICKS = 250        # 一个字多长（tick）
STRESS_TICKS = 300      # 句首那个字
WEAK_TICKS = 190        # 虚字（的/了/也/就…）短一点
PHRASE_END_TICKS = 560  # 句末那个字拖长一点（原来是 420，太赶）
PHRASE_GAP_TICKS = 300  # 句号处留的空（tick）
WEAK_GAP_TICKS = 150    # 逗号处留的空：短一点，也不换气
LEAD_TICKS = 480        # 开头留一拍，给第一口换气

# 音阶：五声音阶，两级八度（相对主音的半音）。★ 2026-11-02 他说「音调起伏有点低，像念诗」⇒
# 把音域从原来 62~74（不到一个八度）拉到 64~78（E4~F#5），并且每句走一个拱形/上行/下行轮廓。
LADDER = [0, 2, 4, 7, 9, 12, 14, 16]
TONIC = 64              # E4
PARTICLES = set("的了也就在是不和着过们地得")

# OpenUtau 的渲染以「首音 tick − headFrames×frameMs」为时间原点（DiffSingerUtils: 8 帧 × 512/44100）
SR = 44100
HEAD_S = 8 * 512 / 44100.0

# 颤音（原生 vibrato，单位：length=音符长度的百分比，period=毫秒，depth=音分）
VIB_MIN_TICKS = 300
VIB = dict(length=float(_CFG.get("vibrato", 42.0) or 0.0),
           period=168.0, depth=26.0, inn=30.0, out=35.0)

PUNCT = "，。、！？；：,.!?;: \t\r\n\u3000"
STRONG = "。！？!?.\n\r"          # 句号类：留长空、给换气
WEAK = "，、；：,;: \t\u3000"      # 逗号类：留短空、不换气


# ---------------------------------------------------------------- 谱
def split_phrases(lyrics):
    """按标点/换行切句，句内只留汉字"""
    phrases, cur = [], []
    for ch in lyrics:
        if ch in PUNCT:
            if cur:
                phrases.append("".join(cur))
                cur = []
        elif "\u4e00" <= ch <= "\u9fff":
            cur.append(ch)
        # 其它字符（字母数字等）直接跳过
    if cur:
        phrases.append("".join(cur))
    return phrases


def split_with_gaps(lyrics):
    """切句，并给出每句后面留多长的空（tick）：句号类长、逗号类短、最后不收空"""
    phrases, gaps, cur, gap = [], [], [], PHRASE_GAP_TICKS
    for ch in lyrics:
        if ch in STRONG:
            if cur:
                phrases.append("".join(cur))
                gaps.append(PHRASE_GAP_TICKS)
                cur = []
            gap = PHRASE_GAP_TICKS
        elif ch in WEAK:
            if cur:
                phrases.append("".join(cur))
                gaps.append(WEAK_GAP_TICKS)
                cur = []
            gap = WEAK_GAP_TICKS
        elif "\u4e00" <= ch <= "\u9fff":
            cur.append(ch)
    if cur:
        phrases.append("".join(cur))
        gaps.append(0)
    elif gaps:
        gaps[-1] = 0
    return phrases, gaps


def make_notes(phrases, explicit=None, humanize=True, gaps=None):
    """返回 (notes, spans)

    notes = [(abs_tick, tick_duration, tone, lyric), ...]（含开头留白与句间空）
    spans = [[(pos, dur, tone, ch), ...], ...]  每句一组，pos 相对该句首音（渲染用）

    humanize：句内音符边界 ±12 tick 的抖动（像人在唱，不是节拍器）；
    句子总长与起点不变，所以不影响整首的时间轴。
    """
    if explicit:
        tones = [int(x) for x in explicit.split(",")]
        chars = [c for p in phrases for c in p]
        if len(tones) < len(chars):
            raise SystemExit("--notes 给的音高比字数少：%d < %d" % (len(tones), len(chars)))
    rng = np.random.default_rng(20261102)
    notes, spans = [], []
    pos = LEAD_TICKS
    di = 0
    k = 0                                   # 第几个字（--notes 取音高用）
    for pi, ph in enumerate(phrases):
        group = []
        durs = []
        tones_line = contour(len(ph), pi, len(phrases))
        for ci, ch in enumerate(ph):
            last = ci == len(ph) - 1
            if explicit:
                tone = tones[k]
            else:
                tone = TONIC + LADDER[tones_line[ci]]
            k += 1
            if last:
                durs.append(PHRASE_END_TICKS)
            elif ch in PARTICLES:
                durs.append(WEAK_TICKS)
            elif ci == 0:
                durs.append(STRESS_TICKS)
            else:
                durs.append(NOTE_TICKS)
            group.append([0, 0, tone, ch])
        if humanize and len(group) > 1:
            orig = list(durs)
            for i in range(len(durs) - 1):
                d = durs[i] + int(rng.integers(-10, 11))
                durs[i] = max(170, min(STRESS_TICKS + 40, d))
            durs[-1] = sum(orig) - sum(durs[:-1])
            durs[-1] = max(300, durs[-1])
        for i, (g, d) in enumerate(zip(group, durs)):
            g[0] = pos                          # ★ 位置必须在这里给：上面的 pos 还没走
            g[1] = d
            notes.append((g[0], g[1], g[2], g[3]))
            pos += d
        spans.append([tuple(g) for g in group])
        g_after = gaps[pi] if gaps and pi < len(gaps) else (0 if pi == len(phrases) - 1 else PHRASE_GAP_TICKS)
        pos += g_after
        di += 1
    return notes, spans


def contour(n, pi, total):
    """给一句排一条旋律线条，返回 LADDER 的下标序列

    以前是「±1 度随机游走 + 句末硬落主音」—— 走不出起伏（听着像念诗），
    而且句末硬拽回主音会掉一个八度。现在的规则：
      · **一次只走一到两级**（级进为主，偶尔跳三级），不来回大跳；
      · 前半句朝「拱顶」走、后半句往下走 ⇒ 句子有形状；
      · 收尾两个音一定往下（最后一句落到主音），不硬拽。
    """
    if n <= 0:
        return []
    base = [0, 1, 2, 2, 1, 0][pi % 6]       # 起句高度：整首先上后下
    last_phrase = (pi == total - 1)
    if n == 1:
        return [0 if last_phrase else base]
    if n == 2:
        return [base + 1, 0 if last_phrase else max(0, base - 1)]
    rng = np.random.default_rng(1000 + pi)
    top = base + 2.4
    idx = [base]
    for i in range(1, n):
        pos = i / float(n - 1)
        target = base + (top - base) * np.sin(np.pi * min(1.0, pos * 1.02))
        d = target - idx[-1]
        if d > 1.3:
            step = int(rng.choice([1, 1, 2]))
        elif d > 0.25:
            step = int(rng.choice([1, 1, 0, -1]))
        elif d < -1.3:
            step = int(rng.choice([-1, -1, -2]))
        else:
            step = int(rng.choice([-1, 0, 1]))
        idx.append(int(np.clip(idx[-1] + step, 0, len(LADDER) - 1)))
    # 收尾一定往下
    if n >= 2:
        if last_phrase:
            idx[-2] = min(idx[-2], 1)
            idx[-1] = 0
        else:
            idx[-1] = max(0, idx[-2] - 1)
    return [int(v) for v in idx]


def write_ustx(path, notes, bpm, vib=True):
    total = (notes[-1][0] + notes[-1][1] if notes else 0) + 480
    L = []
    a = L.append
    a('ustx_version: "0.9"')
    a('name: svs')
    a("comment: ''")
    a('output_dir: Vocal')
    a('cache_dir: UCache')
    a('key: 0')
    a('expressions: {}')
    a('exp_selectors: [dyn, pitd, clr, eng, vel, vol, atk, dec, gen, bre]')
    a('exp_primary: 0')
    a('exp_secondary: 1')
    a('time_signatures:')
    a('- bar_position: 0')
    a('  beat_per_bar: 4')
    a('  beat_unit: 4')
    a('tempos:')
    a('- position: 0')
    a('  bpm: %d' % bpm)
    a('tracks:')
    a('- singer: %s' % SINGER)
    a('  phonemizer: OpenUtau.Core.DiffSinger.DiffSingerChinesePhonemizer')
    a('  renderer_settings:')
    a("    renderer: ''")          # 留空 ⇒ 用该声库的默认渲染器（填别的会拿到 null）
    a("    resampler: ''")
    a("    wavtool: ''")
    a('  track_name: 绮萱')
    a('  track_color: Blue')
    a('  mute: false')
    a('  solo: false')
    a('  volume: 0.0')
    a('  pan: 0.0')
    a('  track_expressions: []')
    a("  voice_color_names: ['']")
    a('voice_parts:')
    a('- name: part1')
    a('  comment: ""')
    a('  track_no: 0')
    a('  position: 0')
    a('  duration: %d' % total)
    a('  notes:')
    ms_per_tick = 60000.0 / bpm / RES
    for i, (p, d, tone, ch) in enumerate(notes):
        # 长音才给颤音；短音加颤音会把字咬糊
        vl = VIB["length"] if (vib and d >= VIB_MIN_TICKS) else 0.0
        a('  - position: %d' % p)
        a('    duration: %d' % d)
        a('    tone: %d' % tone)
        a('    lyric: %s' % ch)
        a('    pitch:')
        # ★ 转调过渡（2026-11-02 他问的「不同音高之间能不能过渡得自然一点」）：
        #   连续的上一个音存在时，用两个 pitch 点做一段滑音 ——
        #   data[0] 交给 snap_first 去填（OpenUtau 会把它设成「上一个音的音高」：
        #   UNote.Validate 里 `pitch.data[0].Y = (Prev.AdjustedTone - AdjustedTone) * 10`，单位 0.1 半音），
        #   data[1] 落在 glide ms 处、y=0 ⇒ 从上一个音高平滑滑到本音。
        # ★ 2026-11-03 他补的：「并不是所有的转音都要滑音，而是有突然转音，也有渐变的滑音」
        #   ⇒ 按跨度抽签：级进大多滑（人声在窄音程上才会连过去），大跳大多直接换（那是「甩」上去的）。
        prev = notes[i - 1] if i > 0 else None
        legato = prev is not None and (prev[0] + prev[1]) == p
        glide = 0
        if vib and legato:
            iv = abs(tone - prev[2])
            p_glide = {0: 0.0, 1: 0.82, 2: 0.76, 3: 0.52, 4: 0.44, 5: 0.22}.get(iv, 0.12)
            if i == len(notes) - 1 and iv <= 2:
                p_glide = 1.0                     # 句末收在近处，一定滑
            if np.random.default_rng(7000 + i).random() < p_glide * GLIDE_SCALE:
                glide = int(round(min(100.0, 38.0 + 9.0 * iv)))
                glide = int(max(22, min(glide, 0.45 * d * ms_per_tick)))
        if glide > 0:
            a('      data:')
            a('      - {x: 0, y: 0, shape: io}')
            a('      - {x: %d, y: 0, shape: io}' % glide)
            a('      snap_first: true')
        else:
            a('      data: []')
            a('      snap_first: false')
        a('    vibrato:')
        a('      length: %g' % vl)
        a('      period: %g' % VIB["period"])
        a('      depth: %g' % VIB["depth"])
        a('      in: %g' % VIB["inn"])
        a('      out: %g' % VIB["out"])
        a('      shift: 0')
        a('      drift: 0')
        a('      vol_link: 0')
    a('  curves: []')
    a('  masked_curves: []')
    a('wave_parts: []')
    text = "\n".join(L) + "\n"
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)
    return path


# ---------------------------------------------------------------- GUI
def _enum_windows():
    import ctypes
    from ctypes import wintypes
    u = ctypes.windll.user32
    out = []

    @ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
    def cb(hwnd, _):
        n = u.GetWindowTextLengthW(hwnd)
        if n:
            buf = ctypes.create_unicode_buffer(n + 1)
            u.GetWindowTextW(hwnd, buf, n + 1)
            if "OpenUtau" in buf.value:
                out.append((hwnd, buf.value))
        return True

    u.EnumWindows(cb, 0)
    return out


def find_ou_window(timeout=40):
    t0 = time.time()
    while time.time() - t0 < timeout:
        w = _enum_windows()
        if w:
            return w[0][0]
        time.sleep(0.5)
    return None


def press_space():
    import ctypes
    u = ctypes.windll.user32
    u.keybd_event(0x20, 0, 0, 0)
    time.sleep(0.05)
    u.keybd_event(0x20, 0, 2, 0)


def render(ustx_path, timeout=180, log=print):
    """起 OpenUtau 渲染一个工程，返回新产出的 wav 路径"""
    import ctypes
    cache = os.path.join(OU_DIR, "Cache")
    os.makedirs(cache, exist_ok=True)
    before = {f: os.path.getmtime(f) for f in glob.glob(os.path.join(cache, "*.wav"))}

    subprocess.run(["taskkill", "/F", "/IM", "OpenUtau.exe"],
                   capture_output=True)
    time.sleep(1.5)
    subprocess.Popen([OU_EXE, ustx_path], cwd=OU_DIR)
    hwnd = find_ou_window()
    if not hwnd:
        raise SystemExit("OpenUtau 窗口没起来")
    log("窗口已就绪，开始渲染")
    time.sleep(6)                       # 让它把声库读进去
    u = ctypes.windll.user32
    u.SetForegroundWindow(hwnd)
    time.sleep(0.8)
    # ★ 保险：只在 OpenUtau 确实在前台时才发空格，别把按键打到别人窗口里
    if u.GetForegroundWindow() != hwnd:
        u.ShowWindow(hwnd, 9)           # SW_RESTORE
        u.SetForegroundWindow(hwnd)
        time.sleep(0.8)
    if u.GetForegroundWindow() != hwnd:
        raise SystemExit("拿不到前台焦点，为了不误按键，放弃这次渲染")
    t_send = time.time()
    press_space()

    t0 = time.time()
    got = None
    while time.time() - t0 < timeout:
        time.sleep(2)
        # 新文件，或旧文件被重写（同一句再渲染一次时文件名哈希相同，只能看 mtime）
        cand = []
        for f in glob.glob(os.path.join(cache, "*.wav")):
            mt = os.path.getmtime(f)
            if f not in before or mt >= t_send - 1.5:
                cand.append((mt, f))
        if cand:
            cand.sort()
            got = cand[-1][1]
            break
    press_space()
    time.sleep(1)
    subprocess.run(["taskkill", "/F", "/IM", "OpenUtau.exe"], capture_output=True)
    if not got:
        raise SystemExit("等了 %ds 没有渲染出 wav" % timeout)
    log("渲染完成：%s" % os.path.basename(got))
    return got


# ---------------------------------------------------------------- 拼装与好听层
def render_spans(spans, bpm, vib=True, log=print):
    """逐句渲染（一句一个工程），返回 [wav, ...]"""
    out = []
    for i, group in enumerate(spans):
        first = group[0][0]
        rel = [(p - first, d, tone, ch) for (p, d, tone, ch) in group]
        u = os.path.join(PROJ_DIR, "p%02d_%d.ustx" % (i, int(time.time() * 1000) % 10 ** 8))
        write_ustx(u, rel, bpm, vib=vib)
        log("渲染第 %d/%d 句（%d 字）" % (i + 1, len(spans), len(group)))
        out.append(render(u, log=log))
    return out


def assemble(wavs, spans, bpm):
    """按 tick 时间轴把每句拼回去，返回 (单声道 buffer, 每句起点秒)"""
    tick_s = 60.0 / bpm / 480.0
    last = spans[-1][-1]
    total = int((last[0] + last[1]) * tick_s * SR) + int(2.0 * SR)
    buf = np.zeros(total, dtype=np.float32)
    onsets = []
    for w, group in zip(wavs, spans):
        y, sr = sf.read(w)
        if y.ndim > 1:
            y = y.mean(1)
        y = y.astype(np.float32)
        if sr != SR:
            import librosa
            y = librosa.resample(y, orig_sr=sr, target_sr=SR)
        place = int(round((group[0][0] * tick_s - HEAD_S) * SR))
        if place < 0:
            y = y[-place:]
            place = 0
        end = place + len(y)
        if end > len(buf):
            buf = np.pad(buf, (0, end - len(buf)))
        buf[place:end] += y
        onsets.append(group[0][0] * tick_s)
    return buf, onsets


def add_breaths(buf, onsets, level=0.14, seed=7):
    """在每个句首之前放一口吸气。

    ★ 2026-11-02 他说「这个换气不像换气」；2026-11-03 又补「能不能更拟人一点」
    ⇒ 不再自己合成噪声（合成出来永远是「风」），改成**从他参考人声里剪一段真吸气**：
      · `voice-test-1793021000935.wav` 23.32~23.88s 有一段教科书式的吸气
        （前一句 23.17 结束 → 23.2~23.35 静 → 23.35~23.9 气流由弱到强再收 → 23.95 下一句开口）；
      · 谱心 2583Hz、>4k 只占 23%、自相关峰 0.17 ⇒ 暗、平、没有音高，正是吸气；
      · 它比说话峰值低约 30dB，按「人声 rms × 0.14」放回去正好是原来的响度。
      · 每次随机取模板的一段、时长 ±12%、电平 ±1dB ⇒ 不会每口都一样。
    拿不到参考音频时退回合成噪声（`_synth_breath`）。
    """
    if level <= 0:
        return buf
    rng = np.random.default_rng(seed)
    voiced = buf[np.abs(buf) > 0.01]
    ref = float(np.sqrt(np.mean(voiced ** 2))) if voiced.size else 0.05
    lib = load_breaths()
    for t in onsets:
        if lib:
            src = lib[int(rng.integers(0, len(lib)))]
            dur_want = float(rng.uniform(0.26, 0.40))
            n = max(1, int(dur_want * SR))
            if len(src) >= n:
                # 从模板开头附近取（保住「由弱到强」的形状，砍掉尾巴）
                st = int(rng.integers(0, max(1, int(0.15 * len(src)))))
                x = src[st:st + n].copy()
            else:
                x = np.interp(np.linspace(0, len(src) - 1, n),
                              np.arange(len(src)), src).astype(np.float32)
            f = int(0.008 * SR)
            if len(x) > 2 * f:
                x[:f] *= np.linspace(0, 1, f)
                x[-f:] *= np.linspace(1, 0, f)
            x *= float(10 ** (rng.uniform(-1.0, 1.0) / 20.0))
        else:
            x = _synth_breath(rng)
        x = x / (np.sqrt(np.mean(x ** 2)) + 1e-9) * ref * level
        start_i = int((t - 0.07 - len(x) / SR) * SR)
        if start_i < 0:
            continue
        end = min(len(buf), start_i + len(x))
        buf[start_i:end] += x[:end - start_i]
    return buf


def _synth_breath(rng):
    """退路：合成一口吸气（参考音频找不到时用）"""
    from scipy.signal import butter, lfilter
    n = max(1, int(float(rng.uniform(0.20, 0.28)) * SR))
    noise = rng.standard_normal(n).astype(np.float32)
    b1, a1 = butter(2, [500 / (SR / 2), 4200 / (SR / 2)], btype="band")
    x = lfilter(b1, a1, noise).astype(np.float32)
    b3, a3 = butter(2, 1200 / (SR / 2), btype="low")
    x = 0.7 * x + 0.5 * lfilter(b3, a3, noise).astype(np.float32)
    u = np.linspace(0.0, 1.0, n)
    env = np.clip(u / 0.15, 0, 1) * np.clip((1.0 - u) / 0.25, 0, 1)
    return (x * env).astype(np.float32)


_BREATH_CACHE = None
REF_VOICE = REF_VOICE_CFG or (r"C:\Users\lenovo\Documents\deepseek-harness\default-workspace"
                              r"\dafeiyu\state\call\voice-test-1793021000935.wav")
# 参考人声里那段真吸气（2026-11-03 从 voice-test 里挑出来的）。
# 换了参考音色就自动去扫（`_auto_breath_window`），别指望这个秒数还准。
BREATH_WINDOWS = [(23.32, 23.88)]


def _auto_breath_window(y, sr=SR):
    """在别人的参考录音里自动找一段吸气：不响、没音高、谱心 1.5~4kHz。

    判据来自他这份参考音频里那段真吸气（谱心 2583Hz、>4k 占 23%、自相关峰 0.17），
    而说话段是谱心 ~1300Hz、自相关峰 ~0.9 ⇒ 「暗 + 平 + 没音高」就能把它分出来。
    """
    try:
        import librosa
    except Exception:                    # noqa: BLE001
        return None
    hop = 256
    rms = librosa.feature.rms(y=y, frame_length=1024, hop_length=hop)[0]
    f0, vflag, _ = librosa.pyin(y, fmin=80, fmax=800, sr=sr, frame_length=1024, hop_length=hop)
    vflag = np.nan_to_num(vflag).astype(bool)
    vr = rms[vflag & np.isfinite(f0)]
    if vr.size < 10:
        return None
    ref = float(np.median(vr))
    quiet = (rms > ref * 0.02) & (rms < ref * 0.35) & (~vflag)
    times = librosa.times_like(rms, sr=sr, hop_length=hop)
    best, i = None, 0
    while i < len(times):
        if not quiet[i]:
            i += 1
            continue
        j = i
        while j < len(times) and quiet[j]:
            j += 1
        t0, t1 = float(times[i]), float(times[min(j, len(times) - 1)])
        if 0.25 <= (t1 - t0) <= 0.9:
            seg = y[int(t0 * sr):int(t1 * sr)]
            S = np.abs(librosa.stft(seg, n_fft=1024, hop_length=256)).mean(axis=1)
            fr = librosa.fft_frequencies(sr=sr, n_fft=1024)
            cent = float((fr * S).sum() / (S.sum() + 1e-9))
            if 1200 <= cent <= 4200 and len(seg) > int(0.25 * sr):
                if best is None or (t1 - t0) > (best[1] - best[0]):
                    best = (t0, t1)
        i = j
    return best


def load_breaths():
    """从参考人声里剪出真吸气分段（带几个时长变体），失败返回空表

    先试写死的那段（这副参考音频里挑好的）；音频不够长就自动扫一段；
    都找不到就交给 `_synth_breath`。
    """
    global _BREATH_CACHE
    if _BREATH_CACHE is not None:
        return _BREATH_CACHE
    lib = []
    try:
        y, sr = sf.read(REF_VOICE)
        if y.ndim > 1:
            y = y.mean(1)
        y = y.astype(np.float32)
        if sr != SR:
            import librosa
            y = librosa.resample(y, orig_sr=sr, target_sr=SR)
        wins = [(a, b) for (a, b) in BREATH_WINDOWS if b * SR < len(y) - 1]
        if not wins:
            auto = _auto_breath_window(y, SR)
            if auto:
                wins = [auto]
        for (a, b) in wins:
            seg = y[int(a * SR):int(b * SR)].copy()
            if len(seg) < int(0.15 * SR):
                continue
            seg -= float(np.median(seg))          # 去直流
            f = int(0.02 * SR)                    # 两头各 20ms 淡入淡出，别带出前后音
            seg[:f] *= np.linspace(0, 1, f)
            seg[-f:] *= np.linspace(1, 0, f)
            seg = seg / (np.sqrt(np.mean(seg ** 2)) + 1e-9)
            lib.append(seg.astype(np.float32))
            for k in (0.85, 1.15):                # 时长变体
                n2 = int(len(seg) * k)
                v = np.interp(np.linspace(0, len(seg) - 1, n2),
                              np.arange(len(seg)), seg).astype(np.float32)
                lib.append(v / (np.sqrt(np.mean(v ** 2)) + 1e-9))
    except Exception:                            # noqa: BLE001
        lib = []
    _BREATH_CACHE = lib
    return lib



def add_air(buf, level=0.04):
    """很轻的一层气声：宽带噪声压在 3k 以上，跟人声一起走"""
    from scipy.signal import butter, lfilter
    if level <= 0:
        return buf
    b, a = butter(2, 3000 / (SR / 2), btype="high")
    return (buf + level * lfilter(b, a, buf)).astype(np.float32)


def _ir(rng, t60=1.35, predelay=0.02):
    from scipy.signal import butter, lfilter
    n = int(t60 * SR)
    t = np.arange(n) / SR
    x = rng.standard_normal(n).astype(np.float32) * np.exp(-6.9078 * t / t60)
    b, a = butter(2, 5200 / (SR / 2), btype="low")
    x = lfilter(b, a, x).astype(np.float32)
    pre = int(predelay * SR)
    x = np.concatenate([np.zeros(pre, dtype=np.float32), x])
    x = x / (np.sqrt(np.sum(x ** 2)) + 1e-9)
    for dt, g in ((0.011, 0.6), (0.019, 0.4), (0.028, 0.28), (0.041, 0.18)):
        k = int(dt * SR) + pre
        if k < len(x):
            x[k] += g
    return x


def add_reverb(buf, wet=0.22, seed=11):
    """两条去相关的 IR 做左右声道 ⇒ 一点点宽度与空间"""
    from scipy.signal import butter, fftconvolve, lfilter
    if wet <= 0:
        return np.stack([buf, buf], 1).astype(np.float32)
    b, a = butter(2, 180 / (SR / 2), btype="high")
    send = lfilter(b, a, buf).astype(np.float32)
    rng = np.random.default_rng(seed)
    wl = fftconvolve(send, _ir(rng))[:len(buf)].astype(np.float32)
    wr = fftconvolve(send, _ir(rng))[:len(buf)].astype(np.float32)
    return np.stack([buf + wet * wl, buf + wet * wr], 1).astype(np.float32)


def normalize_peak(x, target=0.89):
    m = float(np.max(np.abs(x))) if x.size else 0.0
    return x if m < 1e-9 else (x * (target / m)).astype(np.float32)


# ---------------------------------------------------------------- 后处理
def to_mp3(wav_in, mp3_out, sr=44100):
    r = subprocess.run(["ffmpeg", "-y", "-v", "error", "-i", wav_in,
                        "-af", "loudnorm=I=-16:TP=-1.5:LRA=11",
                        "-ar", str(sr), "-b:a", "192k", mp3_out],
                       capture_output=True, text=True, encoding="utf-8", errors="replace")
    if r.returncode != 0:
        raise SystemExit("ffmpeg 失败：" + (r.stderr or "")[-400:])
    return mp3_out


def convert_her(wav_in, wav_out, steps=40, cfg=0.5):
    r = subprocess.run([PY, SING_PY, "--source", wav_in, "--out", wav_out,
                        "--steps", str(steps), "--cfg-rate", str(cfg)],
                       capture_output=True, text=True, encoding="utf-8", errors="replace")
    if r.returncode != 0 or not os.path.exists(wav_out):
        raise SystemExit("Seed-VC 失败：" + (r.stderr or "")[-600:])
    return wav_out


def _whisper_dir():
    root = _SING.get("seedvc_root") or ""
    cand = os.path.join(root, "checkpoints", "whisper-small") if root else ""
    if cand and os.path.isdir(cand):
        return cand
    return "openai/whisper-small"


def verify(wav_path, lyric_ref):
    """不带任何提示的 ASR —— 这是他自己定的验收标准

    ★ 两个分数都给：`ratio`（按字比，whisper 偶尔吐繁体就虚低）
      和 `py_ratio`（按拼音比，更接近「听不听得清」，同音字不算错）。
      验收一律看 `py_ratio`。
    """
    code = r'''
import sys, difflib, json, librosa, torch
from transformers import WhisperForConditionalGeneration, WhisperProcessor
WD = sys.argv[3]
DEV = "cuda" if torch.cuda.is_available() else "cpu"
proc = WhisperProcessor.from_pretrained(WD)
m = WhisperForConditionalGeneration.from_pretrained(WD).to(DEV); m.eval()
y, _ = librosa.load(sys.argv[1], sr=16000)
with torch.no_grad():
    f = proc(y, sampling_rate=16000, return_tensors="pt").input_features.to(DEV)
    ids = m.generate(f, language="zh", task="transcribe", max_new_tokens=120)
t = proc.batch_decode(ids, skip_special_tokens=True)[0]
try:
    from pypinyin import lazy_pinyin
    py = lambda s: " ".join(lazy_pinyin(s))
    pyr = difflib.SequenceMatcher(None, py(sys.argv[2]), py(t)).ratio()
except Exception:
    pyr = 0.0
print(json.dumps({"heard": t,
                  "ratio": difflib.SequenceMatcher(None, sys.argv[2], t).ratio(),
                  "py_ratio": pyr}, ensure_ascii=False))
'''
    r = subprocess.run([PY, "-c", code, wav_path, lyric_ref, _whisper_dir()],
                       capture_output=True, text=True, encoding="utf-8", errors="replace")
    if r.returncode != 0:
        raise SystemExit("ASR 失败：" + (r.stderr or "")[-600:])
    return json.loads(r.stdout.strip().splitlines()[-1])


# ---------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lyrics", default="")
    # ★ 中文不过命令行：界面/脚本把词写进 UTF-8 文件传进来（ACP=936 会把命令行里的中文搞坏）
    ap.add_argument("--lyrics-file", default="", help="词写在文件里（UTF-8），优先于 --lyrics")
    ap.add_argument("--notes", default="", help="逗号分隔的 MIDI 音高，不给就自己排五声音阶")
    ap.add_argument("--tempo", type=int, default=BPM_DEFAULT)
    ap.add_argument("--out", default="")
    ap.add_argument("--her", action="store_true", help="过 Seed-VC 换成我的音色")
    ap.add_argument("--voice", choices=["her", "singer"], default="",
                    help="用谁的音色（默认读配置；singer = 声库原声）")
    ap.add_argument("--verify", action="store_true", help="跑无提示 ASR 打分（默认按配置）")
    ap.add_argument("--no-verify", action="store_true", help="这次不跑 ASR 自查")
    ap.add_argument("--dry", action="store_true", help="关掉颤音/换气/气声/混响/滑音（对照用）")
    ap.add_argument("--reverb", type=float, default=float(_CFG.get("reverb", 0.16)), help="混响湿声量 0~1")
    ap.add_argument("--breath", type=float, default=float(_CFG.get("breath", 0.14)), help="换气声量（相对人声 rms）")
    ap.add_argument("--air", type=float, default=0.04, help="气声层量 0~0.3")
    ap.add_argument("--glide", type=float, default=None, help="滑音比例 0~100（覆盖配置）")
    ap.add_argument("--check", action="store_true", help="只检查环境，不出声（给界面用）")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()

    global GLIDE_SCALE
    if a.glide is not None:
        GLIDE_SCALE = max(0.0, min(1.0, a.glide / 100.0))
    if a.lyrics_file:
        with open(a.lyrics_file, "r", encoding="utf-8-sig") as f:
            a.lyrics = f.read()
    voice = a.voice or str(_CFG.get("voice") or "her")
    want_her = a.her or voice == "her"

    if a.check:
        info = {
            "openutau": OU_DIR, "openutau_exe": bool(OU_EXE and os.path.exists(OU_EXE)),
            "singer": SINGER, "singer_ok": bool(SINGER and OU_DIR and
                                                os.path.exists(os.path.join(OU_DIR, "Singers", SINGER, "dsconfig.yaml"))),
            "reference": REF_VOICE, "reference_ok": bool(REF_VOICE and os.path.exists(REF_VOICE)),
            "python": PY, "voice": "her" if want_her else "singer",
            "breaths": len(load_breaths()),
            "ok": bool(OU_EXE and os.path.exists(OU_EXE) and SINGER),
        }
        print(json.dumps(info, ensure_ascii=False))
        return 0 if info["ok"] else 1
    if not (a.lyrics or "").strip():
        raise SystemExit("没有词（--lyrics 或 --lyrics-file）")

    if not (OU_EXE and os.path.exists(OU_EXE)):
        raise SystemExit("找不到 OpenUtau.exe —— 在设置里指一下 OpenUtau 的目录（或设环境变量 DSH_OPENUTAU）")
    if not SINGER:
        raise SystemExit("OpenUtau 的 Singers 目录里没找到声库（要有 dsconfig.yaml 的那种）")

    phrases, gaps = split_with_gaps(a.lyrics)
    if not phrases:
        raise SystemExit("没有可唱的字")
    notes, spans = make_notes(phrases, a.notes or None, gaps=gaps)

    os.makedirs(PROJ_DIR, exist_ok=True)
    out_base = a.out or os.path.join(PROJ_DIR, "out_%d.mp3" % int(time.time()))
    if not os.path.splitext(out_base)[1]:
        out_base += ".mp3"
    stem = os.path.splitext(out_base)[0]
    log = (lambda *x: None) if a.json else (lambda *x: print(*x, flush=True))

    # ① 逐句渲染 → ② 按 tick 拼回时间轴
    wavs = render_spans(spans, a.tempo, vib=not a.dry, log=log)
    vocal, onsets = assemble(wavs, spans, a.tempo)
    dry_wav = stem + "_qixuan.wav"
    sf.write(dry_wav, vocal, SR)
    result = {"phrases": phrases, "notes": len(notes), "wav": dry_wav, "voice": "her" if want_her else "singer",
              "lyric_ref": "".join(phrases), "onsets": [round(x, 3) for x in onsets]}

    # ③ 换音色（放在好听那层之前：吸气是噪声，别让 Seed-VC 去转它）
    if want_her:
        her_wav = stem + "_her.wav"
        convert_her(dry_wav, her_wav)
        y, sr = sf.read(her_wav)
        if y.ndim > 1:
            y = y.mean(1)
        y = y.astype(np.float32)
        if sr != SR:
            import librosa
            y = librosa.resample(y, orig_sr=sr, target_sr=SR)
        if len(y) < len(vocal):
            y = np.pad(y, (0, len(vocal) - len(y)))
        vocal = y[:len(vocal)] if len(y) > len(vocal) else y
        result["wav_her"] = her_wav

    # ④ 好听那层（换气只放在句号处，逗号不换）
    breath_t = [onsets[0]] + [onsets[i] for i in range(1, len(onsets))
                              if i - 1 < len(gaps) and gaps[i - 1] >= PHRASE_GAP_TICKS]
    result["breaths"] = [round(x, 3) for x in breath_t]
    if not a.dry:
        vocal = add_air(vocal, a.air)
        vocal = add_breaths(vocal, breath_t, a.breath)
        out = add_reverb(vocal, a.reverb)
    else:
        out = np.stack([vocal, vocal], 1)
    out = normalize_peak(out)
    mix_wav = stem + "_mix.wav"
    sf.write(mix_wav, out, SR)
    result["wav_mix"] = mix_wav

    mp3 = to_mp3(mix_wav, out_base)
    result["mp3"] = mp3

    do_verify = bool(a.verify or _CFG.get("verify")) and not a.no_verify
    if do_verify:
        ref = "".join(phrases)
        result["verify_final"] = verify(dry_wav, ref)
        if not a.dry:
            result["verify_mix"] = verify(mix_wav, ref)

    if a.json:
        print(json.dumps(result, ensure_ascii=False))
    else:
        print("mp3:", result["mp3"])
        for k in ("verify_final", "verify_mix"):
            if k in result:
                v = result[k]
                print("%s: 拼音重合 %.2f（字面 %.2f）  听到「%s」" % (
                    k, v.get("py_ratio", 0.0), v["ratio"], v["heard"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())

