// dafeiyu/tools/draw-once.mjs —— 命令行画一张，画完把路径打出来。
//
// 为什么要有它（而不是让别的程序直接 import lib/comfy.mjs）：
//   部署界面（tools/setup-ui.ps1）是 PowerShell，它没法 import 一个 .mjs；
//   而 ACP=936 的老毛病是**命令行里的中文会坏**，所以提示词不能当参数传。
//   ⇒ 界面把提示词写进一个 UTF-8 临时文件，这里用 --file 读。
//
//   node dafeiyu/tools/draw-once.mjs "a small orange fish, dark water, rim light"
//   node dafeiyu/tools/draw-once.mjs --file C:\dsh-temp\prompt.txt --size 1024x1216 --seed 42
//   node dafeiyu/tools/draw-once.mjs --file p.txt --model sdxl --open
//
// 输出（stdout）：第一行 = 图的完整路径；第二行 = 用时/模型/seed。失败时退出码 1，原因打在 stderr。
import fs from 'node:fs';
import { spawn } from 'node:child_process';
import { draw } from '../lib/comfy.mjs';

const argv = process.argv.slice(2);
const argOf = (k) => { const i = argv.indexOf(k); return i >= 0 ? argv[i + 1] : null; };

let prompt = '';
const fi = argv.indexOf('--file');
if (fi >= 0) {
  const p = argv[fi + 1];
  try { prompt = fs.readFileSync(p, 'utf8').replace(/^\uFEFF/, '').trim(); } catch (e) {
    console.error('读不到提示词文件：' + p + ' · ' + (e?.message || e));
    process.exit(1);
  }
} else {
  prompt = argv.filter((a, i) => !a.startsWith('--') && !(i > 0 && argv[i - 1].startsWith('--') && argv[i - 1] !== '--open')).join(' ').trim();
}

if (!prompt) {
  console.error('没给提示词。用法：node draw-once.mjs "..." 或 --file <txt>');
  process.exit(1);
}

const size = String(argOf('--size') || '').match(/^(\d+)\s*[x*]\s*(\d+)$/i);
const seedRaw = argOf('--seed');
const o = {
  prompt,
  model: (argOf('--model') || 'flux').toLowerCase(),
  width: size ? Number(size[1]) : undefined,
  height: size ? Number(size[2]) : undefined,
  seed: seedRaw !== null ? Number(seedRaw) : undefined,
};

const r = await draw(o);
if (!r.ok) {
  console.error('画不出来：' + r.error);
  process.exit(1);
}
console.log(r.file);
console.log('(' + r.model + ' · ' + r.seconds + ' 秒 · seed ' + r.seed + ')');

if (argv.includes('--open')) {
  try {
    const p = spawn('cmd.exe', ['/c', 'start', '', r.file], { detached: true, stdio: 'ignore', windowsHide: true });
    p.unref();
  } catch { }
}
