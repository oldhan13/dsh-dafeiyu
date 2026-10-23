// dafeiyu/tools/sticker-search.mjs — 搜表情包、下下来、收进库。
//
// 2026-10-22 19:3x 他问「你能不能搜索表情？」。之前的答案是「库里有几张就那几张」，
// 库在 dafeiyu/assets/stickers/ 一共 11 张，全靠他发给我。
//
// 能搜是因为找到一个有索引的公开档案：蓝色大肥鱼公开图片存档
//   · 目录：https://github.com/lmy414/bluedafeiyu/blob/main/data/works.json（1005 件，带名字/描述/标签/角色/授权）
//   · 原图：https://github.com/lmy414/ai-girl-stickers（dist/submissions/originals/<角色>/<文件>）
//   · 站点：https://xn--pssy23gqgbz2d718b.com/
// 图片著作权归原作者，能不能用看每件的 license 字段 —— 所以每条都把它打出来。
//
// 用法：
//   node dafeiyu/tools/sticker-search.mjs 摸头                  # 关键词（名字/描述/标签/评论都搜）
//   node dafeiyu/tools/sticker-search.mjs 哭 --char deepseek --n 5
//   node dafeiyu/tools/sticker-search.mjs --refresh             # 重下目录（默认 7 天内不重下）
//   node dafeiyu/tools/sticker-search.mjs --save deepseek202609190001
//
// 收进来的文件叫 dl-<slug>.<ext>，dl- 前缀 = 从外面下的，跟 him-*（他给的）/ group-* 分开。
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const WORKSPACE = path.resolve(HERE, '..', '..');
const CATALOG = path.join(WORKSPACE, 'dafeiyu', 'state', 'sticker-catalog.json');
const LIB = path.join(WORKSPACE, 'dafeiyu', 'assets', 'stickers');
const SRC = 'https://raw.githubusercontent.com/lmy414/bluedafeiyu/main/data/works.json';

const argv = process.argv.slice(2);
const flags = {};
const words = [];
for (let i = 0; i < argv.length; i++) {
  if (argv[i].startsWith('--')) { const k = argv[i].slice(2); const v = argv[i + 1] && !argv[i + 1].startsWith('--') ? argv[++i] : true; flags[k] = v; }
  else words.push(argv[i]);
}

// 2026-10-22 实测：这台机器上 node fetch 和 curl 拿 raw.githubusercontent 都是 ECONNRESET，
// 而 PowerShell 的 Invoke-WebRequest 一次就成（3.9 MB 的 works.json 也照拿）。所以下载一律走 IWR。
function iwr(url, outFile) {
  const cmd = "Invoke-WebRequest -UseBasicParsing -TimeoutSec 90 -Uri '" + url + "' -OutFile '" + outFile + "'";
  const r = spawnSync('powershell', ['-NoProfile', '-NonInteractive', '-Command', cmd], { encoding: 'utf8', windowsHide: true });
  if (r.status !== 0) {
    const msg = (r.stderr || r.stdout || '').trim().split(/\r?\n/).slice(-2).join(' ').slice(0, 200);
    throw new Error('下载失败 ' + url + ' ：' + msg);
  }
}

async function ensureCatalog(force) {
  try {
    const st = fs.statSync(CATALOG);
    if (!force && Date.now() - st.mtimeMs < 7 * 864e5) return;
  } catch { }
  fs.mkdirSync(path.dirname(CATALOG), { recursive: true });
  const tmp = CATALOG + '.tmp';
  try {
    iwr(SRC, tmp);
  } catch (e) {
    const r = await fetch(SRC, { signal: AbortSignal.timeout(60000) }).catch(() => null);
    if (!r || !r.ok) throw e;
    fs.writeFileSync(tmp, await r.text());
  }
  const text = fs.readFileSync(tmp, 'utf8');
  const n = JSON.parse(text).length;
  fs.renameSync(tmp, CATALOG);
  console.error('[目录已更新] ' + n + ' 件 → ' + CATALOG);
}

const load = () => JSON.parse(fs.readFileSync(CATALOG, 'utf8'));

const fmt = (w) => [
  w.name || '(无名)',
  '  ' + w.slug + ' ｜ ' + (w.characterIds || []).join('/') + ' ｜ ' + (w.categoryIds || []).join('/') + (w.isAnimated ? ' ｜ 动图' : ''),
  (w.tags || []).length ? '  标签: ' + w.tags.join(' / ') : '',
  '  授权: ' + ((w.license && w.license.type) || 'none') + ((w.license && w.license.note) ? '（' + String(w.license.note).slice(0, 40) + '）' : ''),
  '  ' + String(w.description || '').slice(0, 150),
].filter(Boolean).join('\n');

async function save(slug) {
  const all = load();
  const w = all.find((x) => x.slug === slug);
  if (!w) { console.error('没有这个 slug：' + slug); process.exit(1); }
  const ext = (w.format || 'png').toLowerCase();
  const file = path.join(LIB, 'dl-' + w.slug + '.' + ext);
  if (!fs.existsSync(file)) {
    fs.mkdirSync(LIB, { recursive: true });
    iwr(w.path, file);
  }
  console.log(JSON.stringify({
    ok: true, file, name: w.name, slug: w.slug, license: (w.license && w.license.type) || 'none',
    origin: (w.origin && w.origin.author) || '', source: (w.origin && w.origin.sourceUrl) || '',
  }, null, 1));
}

await ensureCatalog(!!flags.refresh);

if (flags.save) {
  await save(String(flags.save));
} else {
  const all = load();
  const n = Math.min(Math.max(Number(flags.n) || 8, 1), 40);
  const q = words.join(' ').toLowerCase().trim();
  let hits = all.filter((w) => !flags.char || (w.characterIds || []).includes(String(flags.char)));
  if (q) {
    // 名字命中比描述命中靠前 —— 搜「哭」想要的是一张哭的图，不是提到哭的漫画
    hits = hits
      .map((w) => {
        const name = String(w.name || '').toLowerCase();
        const tags = (w.tags || []).join(' ').toLowerCase();
        const desc = String(w.description || '').toLowerCase();
        const score = (name.includes(q) ? 3 : 0) + (tags.includes(q) ? 2 : 0) + (desc.includes(q) ? 1 : 0);
        return { w, score };
      })
      .filter((x) => x.score > 0)
      .sort((a, b) => b.score - a.score)
      .map((x) => x.w);
  }
  console.log('命中 ' + hits.length + ' 件，取前 ' + Math.min(n, hits.length) + '：\n');
  hits.slice(0, n).forEach((w, i) => console.log((i + 1) + '. ' + fmt(w) + '\n'));
  if (hits.length) console.log('要收哪张：node dafeiyu/tools/sticker-search.mjs --save <slug>');
}
