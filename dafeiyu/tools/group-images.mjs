#!/usr/bin/env node
// group-images.mjs —— 群里别人发的图，静默收清单（watch.mjs 落的），需要时我去挑。
//
// 由来（2026-10-22 23:1x，他原话）：「你接受所有人的图，但是如果你判断这张图没用，你就删掉」
// 所以这里**不做判定**，只做三件事：拉下来、让我看、把没用的删掉。
//
// 用法：
//   node dafeiyu/tools/group-images.mjs                 最近 20 条清单（有没有下过）
//   node dafeiyu/tools/group-images.mjs --pull 5        下载最新 5 张没下过的 → group-inbox/
//   node dafeiyu/tools/group-images.mjs --keep <文件>   这张有用：挪进 group-keep/（prune 不动它）
//   node dafeiyu/tools/group-images.mjs --prune [小时]  删掉 group-inbox 里超过 N 小时（默认 24）的
//   node dafeiyu/tools/group-images.mjs --pull 5 --prune  一起干
//
// 下载走 PowerShell 的 Invoke-WebRequest：这台机器上 node fetch / curl 拿腾讯多媒体链会 ECONNRESET（E36）。
// 落地后按魔数改扩展名 —— QQ 的 file 名和真实格式经常对不上（LESSONS 里那条）。

import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '..');            // dafeiyu/
const STATE = path.join(ROOT, 'state', 'group-images.jsonl');
const INBOX = path.join(ROOT, 'assets', 'group-inbox');
const KEEP = path.join(ROOT, 'assets', 'group-keep');

const argv = process.argv.slice(2);
const has = (f) => argv.includes(f);
const val = (f, d) => { const i = argv.indexOf(f); return i >= 0 && argv[i + 1] && !argv[i + 1].startsWith('--') ? argv[i + 1] : d; };

function readList() {
  try {
    return fs.readFileSync(STATE, 'utf8').trim().split('\n').filter(Boolean).map(l => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean);
  } catch { return []; }
}

function fileFor(rec, i) {
  const stamp = new Date(rec.ts).toISOString().replace(/[-:T]/g, '').slice(0, 14);
  const tail = String(rec.mid || stamp).replace(/[^\w-]/g, '');
  return path.join(INBOX, `${rec.gid}-${tail}-${i}.png`);   // 先按 .png 占位，落地后按魔数改名
}
function alreadyPulled(rec, i) {
  const base = fileFor(rec, i).replace(/\.png$/, '');
  try { return fs.readdirSync(INBOX).some(f => f.startsWith(path.basename(base) + '.')) ? path.join(INBOX, fs.readdirSync(INBOX).find(f => f.startsWith(path.basename(base) + '.'))) : ''; }
  catch { return ''; }
}

function magicExt(file) {
  try {
    const b = fs.readFileSync(file).subarray(0, 12);
    const hex = [...b].map(x => x.toString(16).padStart(2, '0')).join('');
    if (hex.startsWith('89504e47')) return '.png';
    if (hex.startsWith('ffd8ff')) return '.jpg';
    if (hex.startsWith('47494638')) return '.gif';
    if (hex.startsWith('52494646') && hex.slice(16, 24) === '57454250') return '.webp';
    if (hex.startsWith('424d')) return '.bmp';
    return '';
  } catch { return ''; }
}

function iwr(url, out) {
  const ps = `Invoke-WebRequest -UseBasicParsing -TimeoutSec 60 -Uri '${url.replace(/'/g, "''")}' -OutFile '${out.replace(/'/g, "''")}'`;
  const r = spawnSync('powershell', ['-NoProfile', '-NonInteractive', '-Command', ps], { encoding: 'utf8', timeout: 90000 });
  return r.status === 0;
}

function cmdList(n) {
  const list = readList().slice(-n).reverse();
  if (list.length === 0) { console.log(JSON.stringify({ ok: true, note: '清单还是空的（watch.mjs 还没收到带图的消息）', entries: [] }, null, 2)); return; }
  const out = list.map((r, i) => ({
    at: new Date(r.ts).toLocaleString('sv-SE', { timeZone: 'Asia/Hong_Kong' }),
    gid: r.gid,
    who: r.nick === String(r.uid) ? r.uid : `${r.nick}(${r.uid})`,
    pulled: alreadyPulled(r, i) || '',
    url: r.url ? r.url.slice(0, 60) + '…' : '(no url)',
  }));
  console.log(JSON.stringify({ ok: true, count: out.length, entries: out }, null, 2));
}

function cmdPull(n) {
  fs.mkdirSync(INBOX, { recursive: true });
  const list = readList().slice(-Math.max(n * 4, n)).reverse();   // 多翻一些，够跳已下过的
  const got = [];
  for (let i = 0; i < list.length && got.length < n; i++) {
    const rec = list[i];
    if (!rec.url) continue;
    if (alreadyPulled(rec, i)) continue;
    const tmp = fileFor(rec, i);
    if (!iwr(rec.url, tmp)) { got.push({ gid: rec.gid, ok: false, why: 'download failed' }); continue; }
    const ext = magicExt(tmp) || '.bin';
    const fin = tmp.replace(/\.png$/, ext);
    try { if (fin !== tmp) fs.renameSync(tmp, fin); } catch { }
    const size = fs.statSync(fin).size;
    got.push({ gid: rec.gid, who: rec.nick, at: new Date(rec.ts).toLocaleString('sv-SE', { timeZone: 'Asia/Hong_Kong' }), path: fin, bytes: size });
  }
  console.log(JSON.stringify({ ok: true, pulled: got.length, items: got, inbox: INBOX }, null, 2));
}

function cmdKeep(file) {
  if (!file || !fs.existsSync(file)) { console.log(JSON.stringify({ ok: false, why: 'file not found', file }, null, 2)); return; }
  fs.mkdirSync(KEEP, { recursive: true });
  const dst = path.join(KEEP, path.basename(file));
  fs.renameSync(file, dst);
  console.log(JSON.stringify({ ok: true, movedTo: dst }, null, 2));
}

function cmdPrune(hours) {
  let removed = 0, kept = 0;
  try {
    const now = Date.now();
    for (const f of fs.readdirSync(INBOX)) {
      const p = path.join(INBOX, f);
      try {
        const st = fs.statSync(p);
        if (now - st.mtimeMs > hours * 3600 * 1000) { fs.unlinkSync(p); removed++; } else kept++;
      } catch { }
    }
  } catch { }
  console.log(JSON.stringify({ ok: true, removed, kept, hours }, null, 2));
}

let did = false;
if (has('--pull')) { cmdPull(Number(val('--pull', '5')) || 5); did = true; }
if (has('--keep')) { cmdKeep(val('--keep', '')); did = true; }
if (has('--prune')) { cmdPrune(Number(val('--prune', '24')) || 24); did = true; }
if (!did) cmdList(Number(val('--list', '20')) || 20);
