#!/usr/bin/env node
/**
 * video-watch —— 把「一条视频」变成「我能看的东西」，并且**用完自己收拾干净**。
 *
 * 为什么需要它：`video-watch-plus` 这个 skill 只吃**本地视频文件**，
 * 而 B 站给的是 BV 号 / 链接。中间那一步（下载）如果每次手搓，
 * 迟早会在磁盘上留下一堆几百 MB 的 mp4 —— 主人 2026-10-23 明确要求
 * 「每次读完视频之后要删除，不要导致堆积」。
 *
 * 所以这里把「下载 → 量测 → 出图板 → 声学侦察 → 清理」串成一条，
 * 并且把清理写成**代码保证**，不靠记性：
 *   · `clips/`（下载的视频）与 `work/`（抽帧中间产物）在**同一次运行结束时就删**，
 *     连分析失败也删（finally）；
 *   · 每次启动先扫一遍，把上一次异常中断留下的残留（>30 分钟）清掉；
 *   · 只保留会用到的东西：图板 png（几十 KB）与文本报告，各留最近 20 份。
 *
 * 用法：
 *   node dafeiyu/tools/video-watch.mjs BV1G2ak69EFT
 *   node dafeiyu/tools/video-watch.mjs "https://www.bilibili.com/video/BV1G2ak69EFT"
 *   node dafeiyu/tools/video-watch.mjs D:\some\clip.mp4          # 本地文件不动它，只在临时目录里抽出帧
 *   node dafeiyu/tools/video-watch.mjs BV1G2ak69EFT --asr        # 连语音转写一起跑（慢）
 *   node dafeiyu/tools/video-watch.mjs BV1G2ak69EFT --frames 36 --cols 6
 *   node dafeiyu/tools/video-watch.mjs --sweep                   # 只清理，不下载
 *   node dafeiyu/tools/video-watch.mjs --status                  # 看占了多少地方
 *   node dafeiyu/tools/video-watch.mjs --purge                   # 连图板与报告一起清空
 *
 * 前置（缺哪样，开跑前就会报出来，不会先下几百 MB 再失败）：
 *   · video-watch-plus 这个 skill —— 默认在 ~/.dsh/skills/video-watch-plus；
 *   · yt-dlp（`python -m yt_dlp`）与 ffmpeg —— 只有给 BV 号/链接时才需要；
 *   · 路径换机器要动的话用环境变量：VIDEO_WATCH_ROOT / VIDEO_WATCH_SKILL。
 *
 * 输出：一段 JSON（给模型读，字段见 main() 里的 result）。
 * 退出码：0 成功 · 1 失败（会把失败原因一起打出来）· 2 参数错 / 前置缺。
 */
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';

const HOME = process.env.USERPROFILE || process.env.HOME || '.';
// 默认都落在用户目录；换盘 / 换机器时说一声就用环境变量指过去
const ROOT = process.env.VIDEO_WATCH_ROOT || path.join(HOME, '.video-watch');
const CLIPS = path.join(ROOT, 'clips');
const WORK = path.join(ROOT, 'work');
const BOARDS = path.join(ROOT, 'boards');
const REPORTS = path.join(ROOT, 'reports');

const SKILL = process.env.VIDEO_WATCH_SKILL || path.join(HOME, '.dsh', 'skills', 'video-watch-plus');
const VW = path.join(SKILL, 'vendor', 'vw.py');
const AUDIO_PROBE = path.join(SKILL, 'scripts', 'audio_probe.py');
const ASR_CHECK = path.join(SKILL, 'scripts', 'asr_hallucination_check.py');

/** 残留判定：超过这个时间的 clips/work 一律清掉（异常中断留下的） */
const STALE_MS = 30 * 60 * 1000;
/** 图板与报告各留最近多少份 */
const KEEP_BOARDS = 20;
const KEEP_REPORTS = 20;

// ---------------------------------------------------------------- 工具
function log(msg) { process.stderr.write(`[video-watch] ${msg}\n`); }

/** 前置检查：skill 的文件在不在（缺了就早点说，别先下几百兆再失败） */
function missingSkillFiles(needAsr) {
  const need = [VW, AUDIO_PROBE];
  if (needAsr) need.push(ASR_CHECK);
  return need.filter((p) => !fs.existsSync(p));
}

/** 前置检查：给 BV/链接时，yt-dlp 得能用 */
async function ytdlpVersion() {
  const r = await run('python', ['-m', 'yt_dlp', '--version'], { timeoutMs: 60000 });
  if (r.code !== 0) return null;
  return (r.out || '').trim().split('\n').pop() || 'ok';
}

/** 跑一个子进程，返回 { code, out, err }；输出按 UTF-8 解（PYTHONIOENCODING 已在 env 里设好） */
function run(cmd, args, { timeoutMs = 10 * 60 * 1000, cwd } = {}) {
  return new Promise((resolve) => {
    const child = spawn(cmd, args, {
      cwd: cwd ?? ROOT,
      windowsHide: true,
      env: { ...process.env, PYTHONIOENCODING: 'utf-8', PYTHONUTF8: '1', HF_ENDPOINT: 'https://hf-mirror.com', HF_HUB_DISABLE_XET: '1' },
    });
    let out = '', err = '';
    const timer = setTimeout(() => {
      // 超时要**连子进程一起杀**：`python -m yt_dlp` 会再拉 ffmpeg 合并，
      // 只 kill 父进程的话 ffmpeg 还攥着那个 mp4，后面就删不掉（清理那条保证会破一个口子）。
      try {
        if (process.platform === 'win32' && child.pid) {
          spawn('taskkill', ['/pid', String(child.pid), '/T', '/F'], { stdio: 'ignore', windowsHide: true });
        } else {
          child.kill('SIGKILL');
        }
      } catch { }
      err += `\n[timeout ${timeoutMs}ms]`;
    }, timeoutMs);
    child.stdout.on('data', (d) => { out += d.toString('utf8'); });
    child.stderr.on('data', (d) => { err += d.toString('utf8'); });
    child.on('error', (e) => { clearTimeout(timer); resolve({ code: -1, out, err: err + '\n' + e.message }); });
    child.on('close', (code) => { clearTimeout(timer); resolve({ code, out, err }); });
  });
}

async function rmrf(p) {
  try { await fsp.rm(p, { recursive: true, force: true }); } catch (e) { log(`清理失败（不影响结果）：${p} ${e.message}`); }
}

async function ensureDirs() {
  for (const d of [CLIPS, WORK, BOARDS, REPORTS]) await fsp.mkdir(d, { recursive: true });
}

async function dirStats(p) {
  let bytes = 0, files = 0;
  try {
    for (const e of await fsp.readdir(p, { withFileTypes: true })) {
      const full = path.join(p, e.name);
      if (e.isDirectory()) { const s = await dirStats(full); bytes += s.bytes; files += s.files; }
      else { const st = await fsp.stat(full); bytes += st.size; files++; }
    }
  } catch { }
  return { bytes, files };
}

/** 只保留最近 N 个文件（按修改时间） */
async function rotate(dir, keep) {
  let list = [];
  try {
    list = (await fsp.readdir(dir, { withFileTypes: true }))
      .filter((e) => e.isFile())
      .map((e) => e.name);
  } catch { return 0; }
  if (list.length <= keep) return 0;
  const withTime = [];
  for (const name of list) {
    try { const st = await fsp.stat(path.join(dir, name)); withTime.push({ name, mtime: st.mtimeMs }); } catch { }
  }
  withTime.sort((a, b) => b.mtime - a.mtime);
  let n = 0;
  for (const { name } of withTime.slice(keep)) { await rmrf(path.join(dir, name)); n++; }
  return n;
}

/**
 * 清扫：把上一次异常中断留下的东西清掉。
 * 这是「不堆积」的兜底 —— 正常路径在 finally 里已经删干净了，
 * 这里治的是进程被杀、断电、脚本中途抛错那种。
 */
async function sweep() {
  await ensureDirs();
  let removed = 0;
  const now = Date.now();
  for (const dir of [CLIPS, WORK]) {
    let list = [];
    try { list = await fsp.readdir(dir, { withFileTypes: true }); } catch { continue; }
    for (const e of list) {
      const full = path.join(dir, e.name);
      let st;
      try { st = await fsp.stat(full); } catch { continue; }
      // clips 里的是视频（大件）：超过 30 分钟没动就删；work 里是中间产物，一并按同一条线
      if (now - st.mtimeMs > STALE_MS) { await rmrf(full); removed++; }
    }
  }
  const rb = await rotate(BOARDS, KEEP_BOARDS);
  const rr = await rotate(REPORTS, KEEP_REPORTS);
  return { removed, rotatedBoards: rb, rotatedReports: rr };
}

// ---------------------------------------------------------------- 输入解析
function parseArgs(argv) {
  const o = { input: '', asr: false, frames: 25, cols: 5, maxHeight: 720, keepVideo: false, sweepOnly: false, purge: false, status: false, help: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--asr') o.asr = true;
    else if (a === '--keep') o.keepVideo = true;
    else if (a === '--sweep') o.sweepOnly = true;
    else if (a === '--purge') o.purge = true;
    else if (a === '--status') o.status = true;
    else if (a === '--help' || a === '-h') o.help = true;
    else if (a === '--frames') o.frames = Number(argv[++i]) || 25;
    else if (a === '--cols') o.cols = Number(argv[++i]) || 5;
    else if (a === '--max-height') o.maxHeight = Number(argv[++i]) || 720;
    else if (!a.startsWith('-')) o.input = a;
  }
  return o;
}

const BV_RE = /\bBV[0-9A-Za-z]{8,12}\b/;
const URL_RE = /^https?:\/\//i;

/** 文件名里只留安全字符（本地文件名可能带空格、括号、井号） */
function safeTag(s) {
  const t = String(s ?? '').replace(/[^\w.\u4e00-\u9fa5-]+/g, '_').replace(/^_+|_+$/g, '').slice(0, 60);
  return t || 'video';
}

/** 秒 → mm:ss.s */
function fmtTs(sec) {
  const s = Math.max(0, Number(sec) || 0);
  const m = Math.floor(s / 60);
  const r = s - m * 60;
  return `${m}:${r.toFixed(1).padStart(4, '0')}`;
}

/** 把输入归一成 { kind: 'local'|'url', value, tag } */
function resolveInput(raw) {
  if (!raw) return null;
  if (fs.existsSync(raw) && fs.statSync(raw).isFile()) {
    return { kind: 'local', value: path.resolve(raw), tag: safeTag(path.basename(raw, path.extname(raw))) };
  }
  const bv = raw.match(BV_RE);
  if (bv) return { kind: 'url', value: `https://www.bilibili.com/video/${bv[0]}`, tag: bv[0] };
  if (URL_RE.test(raw)) return { kind: 'url', value: raw, tag: 'video-' + Date.now().toString(36) };
  return null;
}

// ---------------------------------------------------------------- 主流程
async function download(v, destBase, maxHeight) {
  const out = destBase + '.%(ext)s';
  const h = Number(maxHeight) > 0 ? Number(maxHeight) : 720;
  const fmt = `bv*[height<=${h}]+ba/b[height<=${h}]/b`;
  const r = await run('python', [
    '-m', 'yt_dlp',
    '--no-playlist', '--no-warnings', '--no-progress',
    '-f', fmt, '--merge-output-format', 'mp4',
    '-o', out,
    v.value,
  ], { timeoutMs: 15 * 60 * 1000 });

  // yt-dlp 会把结果落到 destBase.*，找回它
  let found = null;
  try {
    const list = (await fsp.readdir(CLIPS)).filter((n) => n.startsWith(path.basename(destBase) + '.'));
    let best = 0;
    for (const n of list) {
      const st = await fsp.stat(path.join(CLIPS, n));
      if (st.size > best) { best = st.size; found = path.join(CLIPS, n); }
    }
  } catch { }
  return { ok: r.code === 0 && found !== null, file: found, err: r.err, out: r.out };
}

function pickNumber(out, re, fallback = null) {
  const m = out.match(re);
  return m ? Number(m[1]) : fallback;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  await ensureDirs();

  if (args.help) {
    process.stdout.write([
      '用法：node video-watch.mjs <BV号|URL|本地视频> [--asr] [--frames 25] [--cols 5] [--max-height 720] [--keep]',
      '      node video-watch.mjs --sweep      清掉中断留下的残留（>30 分钟的 clips/work）',
      '      node video-watch.mjs --purge      全清（图板 / 报告 / clips / work），看完就扔',
      '      node video-watch.mjs --status     看占了多少地方',
      '',
      '默认跑完就删视频与中间产物；--keep 才留。--asr 会多跑语音转写 + 幻觉证伪（慢）。',
    ].join('\n') + '\n');
    return 0;
  }

  if (args.status) {
    const clips = await dirStats(CLIPS);
    const work = await dirStats(WORK);
    const boards = await dirStats(BOARDS);
    const reports = await dirStats(REPORTS);
    process.stdout.write(JSON.stringify({
      ok: true,
      root: ROOT,
      clipsMB: +(clips.bytes / 1048576).toFixed(2),
      workMB: +(work.bytes / 1048576).toFixed(2),
      boardsMB: +(boards.bytes / 1048576).toFixed(2),
      reportsMB: +(reports.bytes / 1048576).toFixed(2),
      boards: boards.files, reports: reports.files,
      note: 'clips 与 work 正常应当是 0 —— 它们在同一次运行结束时就该被删掉',
    }, null, 2) + '\n');
    return 0;
  }

  if (args.sweepOnly) {
    const s = await sweep();
    process.stdout.write(JSON.stringify({ ok: true, swept: s }, null, 2) + '\n');
    return 0;
  }

  // 看完就清空：图板、报告、以及 clips/work 里万一剩下的东西，一起清掉
  // （主人 2026-10-23：「读完就删，不要堆积」）
  if (args.purge) {
    const counts = {};
    for (const [name, dir] of [['boards', BOARDS], ['reports', REPORTS], ['clips', CLIPS], ['work', WORK]]) {
      let n = 0;
      try { for (const f of await fsp.readdir(dir)) { await rmrf(path.join(dir, f)); n++; } } catch { }
      counts[name] = n;
    }
    const bytes = (await dirStats(ROOT)).bytes;
    process.stdout.write(JSON.stringify({
      ok: true, purged: counts, rootMB_after: +(bytes / 1048576).toFixed(2),
    }, null, 2) + '\n');
    return 0;
  }

  const v = resolveInput(args.input);
  if (!v) {
    process.stderr.write('参数错：给一个 BV 号 / 视频链接 / 本地视频路径。\n');
    return 2;
  }
  // 先把上一次的残留清掉（顺带轮转旧图板）
  const swept = await sweep();

  // 前置：skill 的文件在不在、要不要 yt-dlp —— 都在下载之前说，别下到一半才失败
  const miss = missingSkillFiles(args.asr);
  if (miss.length) {
    process.stderr.write(
      '缺 video-watch-plus 的文件：\n  ' + miss.join('\n  ') +
      '\n先装那个 skill（默认 ~/.dsh/skills/video-watch-plus；换了位置用 VIDEO_WATCH_SKILL 指过去），再跑这条\n');
    return 2;
  }
  let ytdlp = null;
  if (v.kind === 'url') {
    ytdlp = await ytdlpVersion();
    if (!ytdlp) {
      process.stderr.write('没有 yt-dlp：python -m pip install -U yt-dlp -i https://pypi.tuna.tsinghua.edu.cn/simple\n');
      return 2;
    }
    log(`yt-dlp ${ytdlp}`);
  }

  const stamp = new Date().toISOString().replace(/[-:T]/g, '').slice(0, 14);
  const workDir = path.join(WORK, `${v.tag}-${stamp}`);
  await fsp.mkdir(workDir, { recursive: true });

  const result = {
    ok: false, input: v.value, tag: v.tag, swept,
    ytdlp: ytdlp ?? undefined,
    downloaded: null, durationSec: null, board: null, report: null,
    probe: {}, audio: {}, asr: null, workDir, error: null,
  };

  let videoFile = null;
  let localInput = false;
  try {
    // 1) 拿到视频文件
    if (v.kind === 'local') {
      localInput = true;
      videoFile = v.value;
      log(`用本地文件，不动它：${videoFile}`);
    } else {
      log(`下载 ${v.tag}（≤${args.maxHeight}p）…`);
      const dl = await download(v, path.join(CLIPS, `${v.tag}-${stamp}`), args.maxHeight);
      if (!dl.ok) throw new Error(`下载失败：${(dl.err || dl.out).split('\n').filter(Boolean).slice(-4).join(' | ')}`);
      videoFile = dl.file;
      result.downloaded = { file: path.basename(dl.file), mb: +(fs.statSync(dl.file).size / 1048576).toFixed(2) };
      log(`下载完成：${result.downloaded.file} ${result.downloaded.mb} MB`);
    }

    // 2) 量测（零 token）
    log('量测全片…');
    const probe = await run('python', [VW, 'probe', videoFile, '--out', workDir], { timeoutMs: 20 * 60 * 1000 });
    const probeText = probe.out + probe.err;
    result.probe.raw_tail = probeText.split('\n').filter(Boolean).slice(-8);
    result.durationSec = pickNumber(probeText, /素材\s+\S+\s+\d+x\d+\s+[\d.]+fps\s+([\d.]+)s/,
      pickNumber(probeText, /([\d.]+)s/, null));
    result.probe.cuts = pickNumber(probeText, /切点\s+(\d+)\s+个/, null);
    result.probe.freezes = pickNumber(probeText, /冻结段\s+(\d+)\s+个/, null);
    result.probe.silences = pickNumber(probeText, /静音事件\s+(\d+)\s+个/, null);
    result.probe.kind = (probeText.match(/内容判型\s+(.+)/) || [])[1]?.trim() ?? null;

    // 3) 图板（我要 read_image 看的东西）
    log(`出图板（${args.frames} 帧 / ${args.cols} 列）…`);
    const grid = await run('python', [VW, 'grid', '--media', videoFile,
      '--frames', String(args.frames), '--cols', String(args.cols), '--out', workDir], { timeoutMs: 20 * 60 * 1000 });
    if (grid.code !== 0) throw new Error(`出图板失败：${(grid.err || grid.out).split('\n').filter(Boolean).slice(-3).join(' | ')}`);

    // 图板挪到 boards/（长久的只有这一张小图），work 里的原样留给清理
    const gridSrc = path.join(workDir, 'grid.png');
    if (!fs.existsSync(gridSrc)) throw new Error('图板没生成（grid.png 不存在）');
    const boardName = `${v.tag}-${stamp}.png`;
    const boardDst = path.join(BOARDS, boardName);
    await fsp.copyFile(gridSrc, boardDst);
    result.board = boardDst;
    result.boardBytes = fs.statSync(boardDst).size;

    // 4) 声学侦察（不依赖语言模型，先判「有没有人声」）
    log('声学侦察…');
    const ap = await run('python', [AUDIO_PROBE, videoFile, '--json', path.join(workDir, 'audio_probe.json')],
      { timeoutMs: 10 * 60 * 1000 });
    const apText = ap.out + ap.err;
    result.audio.verdict = (apText.match(/判型\s+(.+)/) || [])[1]?.trim() ?? null;
    result.audio.raw_tail = apText.split('\n').filter(Boolean).slice(-6);

    // 5) ASR（可选）：先有第 4 步的声学结论，再决定这份转写能不能信
    if (args.asr) {
      log('语音转写 + 幻觉证伪（慢，模型已在本地就别中断）…');
      const asrJson = path.join(workDir, 'asr.json');
      const asr = await run('python', [ASR_CHECK, videoFile, '--model', 'small', '--lang', 'zh', '--json', asrJson],
        { timeoutMs: 30 * 60 * 1000 });
      const asrText = asr.out + asr.err;
      let j = null;
      try { j = JSON.parse(fs.readFileSync(asrJson, 'utf8')); } catch { }
      if (j) {
        const segs = (j.vad_segments || []).map((s) => ({
          start: +Number(s.start).toFixed(2), end: +Number(s.end).toFixed(2), text: s.text,
        }));
        result.asr = {
          verdict: j.verdict,
          reasons: j.reasons || [],
          uniqueRatio: j.unique_ratio ?? null,
          vadSegments: segs.length,
          // 只回放前面一小段，全文落在 reports/ 那份 md 里 —— 要看再读文件，别整段灌进上下文
          preview: segs.slice(0, 40),
          totalSegments: segs.length,
        };
        if (segs.length) {
          const asrDst = path.join(REPORTS, `${v.tag}-${stamp}.asr.md`);
          try {
            await fsp.writeFile(asrDst, [
              `# ${v.tag} · 转写`,
              '',
              `- 判定：${j.verdict}`,
              `- unique 比：${j.unique_ratio} · VAD ${segs.length} 段 · 模型 ${j.model ?? 'small'}`,
              ...(j.reasons || []).map((r) => `- 理由：${r}`),
              '',
              '> ⚠️ 这是语音转写，不是字幕；有画面字时以画面为准。',
              '> ⚠️ 上面判定若是「幻觉 / 无人声」，下面这些字一句都别当真的引用。',
              '',
              ...segs.map((s) => `[${fmtTs(s.start)} → ${fmtTs(s.end)}] ${s.text}`),
              '',
            ].join('\n'), 'utf8');
            result.asr.report = asrDst;
          } catch { }
        }
      } else {
        // JSON 没读出来就退回读 stdout，至少把判定带回来
        result.asr = {
          verdict: (asrText.match(/判定为(.+)/) || [])[1]?.trim() ?? null,
          raw_tail: asrText.split('\n').filter(Boolean).slice(-10),
        };
      }
    }

    // 6) 文本报告（小，留着）。
    //    `report` 要 shotlist.json，而它由 `plan` 从 timeline 生成 —— 以前漏了这一步，
    //    结果 report 永远是 null（不影响其它产物）。这里补上，plan 失败也只当没有报告。
    //    ⚠️ `plan --out` 要的是**文件路径**，不是目录：第一版传了 workDir，vw.py 里
    //    `open(path,'w')` 直接 PermissionError（目录不能当文件写），report 于是永远 null。
    const shotlist = path.join(workDir, 'shotlist.json');
    if (!fs.existsSync(shotlist)) {
      const pl = await run('python', [VW, 'plan', path.join(workDir, 'timeline.json'), '--out', shotlist],
        { timeoutMs: 5 * 60 * 1000 });
      if (pl.code !== 0) log(`plan 没跑成（报告会缺）：${(pl.err || pl.out).split('\n').filter(Boolean).slice(-2).join(' | ')}`);
    }
    const rep = await run('python', [VW, 'report', path.join(workDir, 'timeline.json'),
      shotlist, '--out', path.join(workDir, 'report.md'),
      // grid 的 manifest.json 里有「第几格 → 哪个时刻」的映射，带上它报告里才会出那张位置表
      ...(fs.existsSync(path.join(workDir, 'manifest.json')) ? ['--manifest', path.join(workDir, 'manifest.json')] : []),
    ], { timeoutMs: 5 * 60 * 1000 });
    if (rep.code === 0 && fs.existsSync(path.join(workDir, 'report.md'))) {
      const repDst = path.join(REPORTS, `${v.tag}-${stamp}.md`);
      await fsp.copyFile(path.join(workDir, 'report.md'), repDst);
      result.report = repDst;
    }

    result.ok = true;
    return 0;
  } catch (e) {
    result.error = e.message;
    log(`失败：${e.message}`);
    return 1;
  } finally {
    // 7) **清理**：视频与中间产物在同一次运行里删掉；异常中断也一样
    if (videoFile && !localInput) {
      if (args.keepVideo) {
        log(`按 --keep 保留视频：${videoFile}`);
        result.keptVideo = videoFile;
      } else {
        await rmrf(videoFile);
        log(`已删除视频：${path.basename(videoFile)}`);
      }
    }
    await rmrf(workDir);
    await rotate(BOARDS, KEEP_BOARDS);
    await rotate(REPORTS, KEEP_REPORTS);
    const after = await dirStats(CLIPS);
    result.clipsMB_after = +(after.bytes / 1048576).toFixed(2);
    process.stdout.write(JSON.stringify(result, null, 2) + '\n');
  }
}

main().then((code) => process.exit(code)).catch((e) => {
  process.stderr.write(`[video-watch] 崩了：${e?.stack || e}\n`);
  process.exit(1);
});
