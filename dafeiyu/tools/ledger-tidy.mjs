// dafeiyu/tools/ledger-tidy.mjs — 让台账自己保持苗条。
//
// 为什么要它：活跃台账是「注入」的，涨到 300 行就会被插件拒绝写入，
// 每次都要人肉归档（而且 ledger_archive 还得把整份新台账一起交上去，很贵）。
//
// 规则（简单到不用记）：
//   1. `/^## |^### /` 开头的行＝一个块的开始；块 = 从这行到下个块之前。
//   2. 文件开头的「前言」（含 `# 大肥鱼 · 活跃台账` 标题）永远保留。
//   3. 从**最后**一个块往前数，能塞进 --keep 行（默认 190）的块留下；
//      中间那些更旧的块搬进 `_ledger-archive/YYYY-MM/weekN/LEDGER-auto.md`（只追加、不删）。
//   4. `## 变更登记` 永远在最后，天然被保留。
//
// 用法：
//   node ledger-tidy.mjs            # 真干
//   node ledger-tidy.mjs --dry      # 只报数
//   node ledger-tidy.mjs --keep 220 # 改目标行数
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const ACTIVE = path.join(ROOT, 'LEDGER.md');
const args = process.argv.slice(2);
const dry = args.includes('--dry');
const keepArg = args.indexOf('--keep');
const KEEP = keepArg >= 0 ? Number(args[keepArg + 1]) : 190;
const THRESHOLD = KEEP + 30;      // 没到「目标 + 30」就先不动，省得每半小时重写一次
const MIN_BLOCKS = 3;             // 至少给后面的块留位置，别把文件切成碎片

const raw = fs.readFileSync(ACTIVE, 'utf8');
const lines = raw.split(/\r?\n/);

if (lines.length <= THRESHOLD) {
  console.log(`ledger ${lines.length} 行 ≤ ${THRESHOLD}，不动。`);
  process.exit(0);
}

// ---- 切块 ----
const isHeading = (l) => /^## /.test(l) || /^### /.test(l);
let firstHeading = lines.findIndex(isHeading);
if (firstHeading < 0) { console.log('没有标题，别动它。'); process.exit(0); }

const preamble = lines.slice(0, firstHeading);
const blocks = [];
let cur = null;
for (let i = firstHeading; i < lines.length; i++) {
  const l = lines[i];
  if (isHeading(l)) {
    if (cur) blocks.push(cur);
    cur = { head: l, body: [l] };
  } else {
    cur.body.push(l);
  }
}
if (cur) blocks.push(cur);

// ---- 从后往前装 ----
let budget = KEEP;
const keep = [];
for (let i = blocks.length - 1; i >= 0 && keep.length < blocks.length; i--) {
  const size = blocks[i].body.length;
  if (keep.length >= MIN_BLOCKS && budget - size < 0) break;
  keep.unshift(blocks[i]);
  budget -= size;
}
const keepSet = new Set(keep.map((b) => b.head));
const archived = blocks.filter((b) => !keepSet.has(b.head));

if (archived.length === 0) {
  console.log(`ledger ${lines.length} 行，但块太大没法只搬旧的，请手工看一眼。`);
  process.exit(0);
}

const archLines = archived.flatMap((b) => b.body);
const newLines = [...preamble, ...keep.flatMap((b) => b.body)]
  .filter((l, i, a) => !(l === '' && a[i - 1] === '' && a[i - 2] === ''));

console.log(`ledger ${lines.length} 行 → ${newLines.length} 行；搬走 ${archived.length} 块 / ${archLines.length} 行。`);
console.log('搬走的块：' + archived.map((b) => b.head.trim()).join(' | ').slice(0, 400));
if (dry) { console.log('(--dry，没写文件)'); process.exit(0); }

// ---- 追加进归档 ----
const now = new Date();
const ym = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}`;
const week = Math.ceil(now.getDate() / 7);
const dir = path.join(ROOT, '_ledger-archive', ym, `week${week}`);
fs.mkdirSync(dir, { recursive: true });
const file = path.join(dir, 'LEDGER-auto.md');
const stamp = now.toLocaleString('zh-CN', { hour12: false });
fs.appendFileSync(file, `\n\n## 自动归档 · ${stamp}（${archived.length} 块 / ${archLines.length} 行）\n\n` + archLines.join('\n') + '\n', 'utf8');

// ---- 写回（先备份）----
fs.copyFileSync(ACTIVE, ACTIVE + '.bak-' + Date.now());
fs.writeFileSync(ACTIVE, newLines.join('\n'), 'utf8');
console.log('归档 → ' + path.relative(ROOT, file));
console.log('活跃台账 → ' + newLines.length + ' 行');
