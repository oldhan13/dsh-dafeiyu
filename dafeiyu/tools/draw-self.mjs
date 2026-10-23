// dafeiyu/tools/draw-self.mjs — 画我自己。
//
// 为什么要有这个脚本：2026-10-22 他说「把你的形象用提示词描述下来，这样你每次画的人都是同一个人」。
// 在那之前每张图都是当场重写一遍描写，靠记性形容 —— 于是第一张和第二张能差半个头。
//
// 现在身份段只有一份：dafeiyu/memory/self-prompt.md 的 ## IDENTITY / ## STYLE。
// 这个脚本**现读那个文件**，所以改词只改 md，不用改代码，也不会两处对不上。
//
// 用法：
//   node dafeiyu/tools/draw-self.mjs "站在窗前，侧脸，窗外下着雨"
//   node dafeiyu/tools/draw-self.mjs "抬手打招呼" --size 832x1216 --seed 123
//
// 输出一行 JSON：{ok, file, seed, seconds}
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { draw } from '../lib/comfy.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const WORKSPACE = path.resolve(HERE, '..', '..');
const PROMPT_MD = path.join(WORKSPACE, 'dafeiyu', 'memory', 'self-prompt.md');

/** 从 self-prompt.md 里按 `## 名字` 切段，返回该段的行（跳过注释和空行）。 */
function sectionOf(md, name) {
  const lines = md.split(/\r?\n/);
  const out = [];
  let inside = false;
  for (const line of lines) {
    if (/^##\s+/.test(line)) {
      inside = line.replace(/^##\s+/, '').trim().toUpperCase() === name.toUpperCase();
      continue;
    }
    if (!inside) continue;
    const t = line.trim();
    if (!t || t.startsWith('>') || t.startsWith('-')) continue;
    out.push(t);
  }
  return out;
}

export function loadSelfPrompt() {
  const md = fs.readFileSync(PROMPT_MD, 'utf8');
  const identity = sectionOf(md, 'IDENTITY');
  const style = sectionOf(md, 'STYLE');
  if (!identity.length) throw new Error('self-prompt.md 里没找到 ## IDENTITY 段');
  return { identity: identity.join(', '), style: style.join(', ') };
}

/** 身份段在前、场景在中间、画风收尾 —— flux 越靠前的词权重越大。 */
export function composePrompt(scene) {
  const { identity, style } = loadSelfPrompt();
  const s = String(scene || '').trim().replace(/,\s*$/, '');
  return [identity, s, style].filter(Boolean).join(', ');
}

const invokedDirectly = !!process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);

if (invokedDirectly) {
  // argv：第一个不带 -- 的参数是场景（可带空格，用引号包住），--size / --seed 各带一个值
  const argv = process.argv.slice(2);
  const sceneParts = [];
  const flags = {};
  for (let i = 0; i < argv.length; i++) {
    if (argv[i].startsWith('--')) { flags[argv[i].slice(2)] = argv[i + 1]; i++; }
    else sceneParts.push(argv[i]);
  }
  const scene = sceneParts.join(' ').trim();
  if (!scene) {
    console.error('要画什么？例：node dafeiyu/tools/draw-self.mjs "站在窗前，侧脸"');
    process.exit(2);
  }
  const [w, h] = String(flags.size || '832x1216').split('x').map(Number);
  const seed = Number(flags.seed);
  const r = await draw({
    prompt: composePrompt(scene),
    model: 'flux',
    width: w || 832,
    height: h || 1216,
    ...(Number.isInteger(seed) && flags.seed ? { seed } : {}),
  });
  console.log(JSON.stringify({ ...r, scene }));
}
