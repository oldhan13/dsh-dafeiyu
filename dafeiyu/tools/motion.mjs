// dafeiyu/tools/motion.mjs —— 把一张动图变成「一眼看得完的一张拼图 + 一份 JSON」。
//
// 为什么要有它（QQ 线的她在 relay/REQUEST-2026-10-21-1345.md 里要的）：
//   read_image 只给一帧，所以 GIF 对她等于一张静止的图；动的那部分完全看不到。
//   现成的 ffmpeg 能把帧抽出来拼成一张，但命令容易拼错（她踩过 fps= 重采样丢帧），
//   而且每格要标上「第几帧 / 第几毫秒」才好引用（"第 5 帧它眨了眼"）。
//   ⇒ 把这件事做成一个稳的 CLI，谁都能直接调。
//
// 用法：
//   node dafeiyu/tools/motion.mjs <文件>                # gif / webp / apng / avif / mp4 / webm
//   node dafeiyu/tools/motion.mjs <文件> --max 12       # 最多取几帧（默认 12）
//   node dafeiyu/tools/motion.mjs <文件> --cell 140     # 每格边长（默认 120）
//   node dafeiyu/tools/motion.mjs <文件> --json         # 只打 JSON，不打路径行
//   node dafeiyu/tools/motion.mjs <文件> --open         # 拼好之后用默认看图程序打开
//
// 输出（stdout）：第一行 = 拼图的完整路径；第二行起 = JSON（"用哪几张、每张几毫秒"都在里面）。
// 失败退出码 1，原因打在 stderr。
//
// 三条规矩（照她的原话）：
//   ① **不信扩展名** —— QQ 那边把 GIF 存成 .jpg，先读 magic bytes 判真身；
//   ② **不许用 fps= 重采样** —— 那会丢帧（她第一次就是这么只拿到 2 帧的）；
//   ③ 产物落**工作区**（dafeiyu/assets/motion/）—— 放 D 盘她读不了、也发不出去。
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const OUT_DIR = path.join(ROOT, 'dafeiyu', 'assets', 'motion');

// ---------- 参数 ----------
const argv = process.argv.slice(2);
const positional = [];
let wantJson = false;
let wantOpen = false;
let maxFrames = 12;
let cellSize = 120;
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (a === '--json') { wantJson = true; continue; }
  if (a === '--open') { wantOpen = true; continue; }
  if (a === '--max') { maxFrames = Math.max(1, parseInt(argv[++i], 10) || 12); continue; }
  if (a === '--cell') { cellSize = Math.max(48, parseInt(argv[++i], 10) || 120); continue; }
  if (a.startsWith('--')) continue;
  positional.push(a);
}
const input = positional[0];
if (!input) {
  console.error('没给文件。用法：node motion.mjs <图片或视频> [--max 12] [--cell 120] [--json] [--open]');
  process.exit(1);
}
const abs = path.resolve(input);
if (!fs.existsSync(abs)) {
  console.error('找不到这个文件：' + abs);
  process.exit(1);
}

// ---------- 1. magic bytes 判真身 ----------
function sniff(file) {
  const fd = fs.openSync(file, 'r');
  try {
    const buf = Buffer.alloc(4096);
    const n = fs.readSync(fd, buf, 0, 4096, 0);
    const b = buf.subarray(0, n);
    const lit = (a, z) => b.subarray(a, z).toString('latin1');
    if (lit(0, 3) === 'GIF') return { kind: 'gif', mime: lit(0, 6) };
    if (lit(0, 4) === 'RIFF' && lit(8, 12) === 'WEBP') return { kind: 'webp' };
    if (b[0] === 0x89 && lit(1, 4) === 'PNG') {
      // APNG 没有独立 magic，靠 acTL 块认；整份扫一遍（图不会太大）
      const all = fs.readFileSync(file);
      return { kind: all.includes(Buffer.from('acTL')) ? 'apng' : 'png' };
    }
    if (b[4] === 0x66 && b[5] === 0x74 && b[6] === 0x79 && b[7] === 0x70) {  // 'ftyp'
      const brand = lit(8, 12).trim();
      if (brand === 'avif' || brand === 'avis') return { kind: 'avif', brand };
      if (brand.startsWith('qt')) return { kind: 'mov', brand };
      return { kind: 'mp4', brand };
    }
    if (b[0] === 0x1a && b[1] === 0x45 && b[2] === 0xdf && b[3] === 0xa3) return { kind: 'webm' };
    if (b[0] === 0xff && b[1] === 0xd8) return { kind: 'jpeg' };
    if (b[0] === 0x42 && b[1] === 0x4d) return { kind: 'bmp' };
    return { kind: 'unknown' };
  } finally {
    fs.closeSync(fd);
  }
}

const truth = sniff(abs);
const ext = path.extname(abs).toLowerCase();
const ANIMATED = new Set(['gif', 'webp', 'apng', 'avif', 'mp4', 'mov', 'webm']);

// ---------- ffmpeg / ffprobe ----------
function run(cmd, args, opts = {}) {
  const r = spawnSync(cmd, args, { encoding: opts.buf ? null : 'utf8', maxBuffer: 512 * 1024 * 1024, windowsHide: true });
  if (r.error) throw new Error(cmd + ' 起不来：' + r.error.message);
  if (r.status !== 0) {
    const err = opts.buf ? (r.stderr || '').toString('utf8') : (r.stderr || '');
    throw new Error(cmd + ' 失败（退出 ' + r.status + '）：' + String(err).trim().split('\n').slice(-3).join(' ').slice(0, 400));
  }
  return r.stdout;
}

function probe(file, countFrames) {
  const a = ['-v', 'error', '-select_streams', 'v:0'];
  if (countFrames) a.push('-count_frames');
  a.push('-show_entries', 'stream=nb_read_frames,nb_frames,width,height,avg_frame_rate,r_frame_rate,duration,codec_name:format=format_name,duration');
  a.push('-of', 'json', file);
  const out = run('ffprobe', a);
  try { return JSON.parse(out || '{}'); } catch { return {}; }
}

function num(v) {
  const n = Number(v);
  return Number.isFinite(n) ? n : 0;
}

// 每帧真实时间戳（gif 每帧 delay 可能不一样，不能拿 i/fps 硬算）
function frameTimes(file, want) {
  try {
    const out = run('ffprobe', ['-v', 'error', '-select_streams', 'v:0',
      '-show_entries', 'frame=pts_time', '-of', 'csv=p=0', file]);
    const t = String(out).split(/\r?\n/).map((s) => parseFloat(s)).filter((x) => Number.isFinite(x));
    if (t.length >= want) return t;
    return t;
  } catch {
    return [];
  }
}

// ---------- 2. 选帧 ----------
function pickIndexes(total, max) {
  if (total <= 0) return [0];
  if (total <= max) return Array.from({ length: total }, (_, i) => i);
  const set = new Set();
  for (let i = 0; i < max; i++) set.add(Math.round((i * (total - 1)) / (max - 1)));
  set.add(0);
  set.add(total - 1);
  return [...set].sort((a, b) => a - b).slice(0, max);
}

// ---------- 3. 帧间差异（粗略就够：缩到 32×32 比像素差） ----------
// ⚠️ 这里必须加 `-fps_mode passthrough`：不加的话 ffmpeg 会按 CFR **补帧**
//    （那只 2 帧的绿猪实测吐出 20 帧，差异分析里全是 delta=0 的重复帧，还报出不存在的"第 10 帧"）。
function frameDiffs(file) {
  try {
    const out = run('ffmpeg', ['-v', 'error', '-i', file, '-vf', 'scale=32:32',
      '-fps_mode', 'passthrough', '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-'], { buf: true });
    const FRAME = 32 * 32 * 3;
    const n = Math.floor(out.length / FRAME);
    if (n < 2) return { frames: n, diffs: [] };
    const diffs = [];
    for (let f = 1; f < n; f++) {
      let s = 0;
      const a = f * FRAME;
      const b = (f - 1) * FRAME;
      for (let i = 0; i < FRAME; i++) s += Math.abs(out[a + i] - out[b + i]);
      diffs.push(s / FRAME);
    }
    return { frames: n, diffs };
  } catch {
    return { frames: 0, diffs: [] };
  }
}

// ---------- 主流程 ----------
(async function main() {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'dfy-motion-'));
  try {
    // --- 探信息 ---
    let info = probe(abs, false);
    let st = (info.streams && info.streams[0]) || {};
    let frames = num(st.nb_read_frames) || num(st.nb_frames);
    if (!frames) {
      info = probe(abs, true);           // 容器里没写帧数，只能真数一遍
      st = (info.streams && info.streams[0]) || {};
      frames = num(st.nb_read_frames) || num(st.nb_frames);
    }
    const w = num(st.width);
    const h = num(st.height);
    let fps = 0;
    const fr = String(st.avg_frame_rate || st.r_frame_rate || '0/1');
    const m = fr.match(/^(\d+)\/(\d+)$/);
    if (m && Number(m[2]) !== 0) fps = Number(m[1]) / Number(m[2]);
    if (!fps && frames) fps = 10;          // 极少数 gif 报 0/0，给个兜底，下面会用真实时间戳修正

    const fmt = (info.format && info.format.format_name) || truth.kind;
    if (!frames) {
      throw new Error('读不出帧数 —— 这不是能解码的动图（真身认成 ' + truth.kind + '）。单张静图直接 read_image 就行。');
    }

    // --- 时间戳 ---
    const times = frames <= 400 ? frameTimes(abs, frames) : [];
    const tOf = (i) => {
      if (times.length > i && Number.isFinite(times[i])) return Math.round(times[i] * 1000);
      return Math.round((i * 1000) / (fps || 1));
    };
    let durationMs = num(info.format && info.format.duration) * 1000;
    if (!durationMs && frames) durationMs = tOf(frames - 1) + Math.round(1000 / (fps || 1));

    // --- 选帧 ---
    const idxs = pickIndexes(frames, maxFrames);

    // --- 抽帧（一次 ffmpeg，select 里逐个列出；不许用 fps= 重采样） ---
    const sel = idxs.map((n) => `eq(n\\,${n})`).join('+');
    run('ffmpeg', ['-y', '-v', 'error', '-i', abs,
      '-vf', `select='${sel}'`,
      '-fps_mode', 'passthrough',
      '-f', 'image2', path.join(tmp, 'f_%03d.png')]);

    // --- 每格：白底 pad + 左上角标「第几帧 / 几毫秒」 ---
    // ⚠️ fontfile 的盘符冒号**必须转义**（`C\:`），而且要连单引号一起写：
    //    `fontfile='C\:/Windows/Fonts/consola.ttf'`。只转义不加引号、或只加引号不转义，都会
    //    报 `No option name near '/Windows/Fonts/...'`（实测）。两个都得有。
    let font = 'C:/Windows/Fonts/consola.ttf';
    if (!fs.existsSync(font)) font = 'C:/Windows/Fonts/arial.ttf';
    const fontArg = `'${font.replace(/:/g, '\\:')}'`;
    const cells = [];
    for (let k = 0; k < idxs.length; k++) {
      const src = path.join(tmp, `f_${String(k + 1).padStart(3, '0')}.png`);
      if (!fs.existsSync(src)) continue;
      const dst = path.join(tmp, `c_${String(cells.length).padStart(3, '0')}.png`);
      const label = `f${idxs[k]}  ${tOf(idxs[k])}ms`;
      const vf = [
        `scale=${cellSize}:${cellSize}:force_original_aspect_ratio=decrease:flags=lanczos`,
        `pad=${cellSize}:${cellSize}:(ow-iw)/2:(oh-ih)/2:white`,
        `drawtext=fontfile=${fontArg}:text='${label}':x=3:y=2:fontsize=11:fontcolor=black:box=1:boxcolor=white@0.88:boxborderw=2`,
      ].join(',');
      run('ffmpeg', ['-y', '-v', 'error', '-i', src, '-vf', vf, '-frames:v', '1', dst]);
      cells.push(dst);
    }
    if (!cells.length) throw new Error('一张帧都没抽出来（这个文件可能只有 1 帧，或者解码失败）');

    // --- 拼图：默认 6 列，多了往下铺（不是拉成一条长带） ---
    const cols = Math.min(6, cells.length);
    const rows = Math.ceil(cells.length / cols);
    if (!fs.existsSync(OUT_DIR)) fs.mkdirSync(OUT_DIR, { recursive: true });
    const stamp = new Date().toISOString().replace(/[-:T]/g, '').slice(0, 14);
    const base = path.basename(abs, path.extname(abs)).replace(/[^\w\u4e00-\u9fa5-]+/g, '_').slice(0, 40) || 'motion';
    const strip = path.join(OUT_DIR, `${base}-${stamp}.png`);
    run('ffmpeg', ['-y', '-v', 'error', '-start_number', '0',
      '-i', path.join(tmp, 'c_%03d.png'),
      '-vf', `tile=${cols}x${rows}:margin=2:padding=2:color=white`,
      '-frames:v', '1', strip]);

    // --- 哪一段变化最大（粗略） ---
    let change = null;
    if (frames <= 400) {
      const d = frameDiffs(abs);
      if (d.diffs.length) {
        // d.diffs[f-1] = 第 f 帧相对第 f-1 帧的变化
        const ranked = d.diffs
          .map((v, i) => ({ frame: i + 1, delta: Math.round(v * 10) / 10 }))
          .sort((a, b) => b.delta - a.delta)
          .slice(0, 3)
          .map((o) => ({ frame: o.frame, tMs: tOf(o.frame), delta: o.delta }));
        change = { sampledFrames: d.frames, top: ranked };
      }
    }

    // --- 输出 ---
    const result = {
      source: abs,
      真身: truth.kind,
      扩展名: ext,
      扩展名骗人: ext !== '' && ext !== '.' + truth.kind && !(truth.kind === 'webm' && ext === '.webm'),
      format: fmt,
      isAnimated: frames > 1,
      frames,
      durationMs: Math.round(durationMs),
      fps: Math.round(fps * 100) / 100,
      size: { w, h },
      strip,
      samples: idxs.map((i, k) => ({ i, tMs: tOf(i), cell: k })),
      change,
    };
    if (!wantJson) console.log(strip);
    console.log(JSON.stringify(result, null, 2));
    if (wantOpen) spawnSync('cmd', ['/c', 'start', '', strip], { windowsHide: true });
  } finally {
    try { fs.rmSync(tmp, { recursive: true, force: true }); } catch { }
  }
})().catch((e) => {
  console.error('motion 失败：' + (e && e.message ? e.message : e));
  process.exit(1);
});
