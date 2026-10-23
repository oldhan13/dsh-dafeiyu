// group-chat.mjs —— 「群里没叫她的时候，她也看得见」的唯一读口。
//
// 数据只有一份：`dafeiyu/group/raw.jsonl`（`group/watch.mjs` 每收一条就落一行，**不只落叫她的**）。
// 这里**只读**，唯一会写的是群名缓存 `dafeiyu/group/groups.json`。
//
// 为什么不再落一个"摘要文件"：那会变成第二份真源 —— 上次重启脚本手抄了一份更短的启动清单，
// 结果桌宠漏在里面 17 小时。**一份数据，两个读的地方（开场简报 / group-peek）。**

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const GROUP_DIR = path.resolve(HERE, '..', 'group');
const RAW_FILE = path.join(GROUP_DIR, 'raw.jsonl');
const NAMES_FILE = path.join(GROUP_DIR, 'groups.json');
const TOKEN_FILE = process.env.DAFEIYU_ONEBOT_TOKEN
  || path.join(process.env.USERPROFILE || process.env.HOME || '.', '.dsh', 'onebot-token.txt');
const NAPCAT = process.env.DAFEIYU_NAPCAT || 'http://127.0.0.1:3000';
const NAMES_MAX_AGE_MS = 6 * 60 * 60 * 1000;

// 只读文件尾巴 —— raw.jsonl 会一直长，不整份读进来
function tailLines(file, maxBytes = 512 * 1024) {
  let fd;
  try {
    const st = fs.statSync(file);
    if (!st.size) return [];
    fd = fs.openSync(file, 'r');
    const start = Math.max(0, st.size - maxBytes);
    const len = st.size - start;
    const buf = Buffer.alloc(len);
    fs.readSync(fd, buf, 0, len, start);
    let s = buf.toString('utf8');
    if (start > 0) s = s.slice(s.indexOf('\n') + 1);   // 砍掉被截断的第一行
    return s.split('\n').filter(Boolean);
  } catch {
    return [];
  } finally {
    if (fd !== undefined) { try { fs.closeSync(fd); } catch { /* ignore */ } }
  }
}

function parseLines(lines) {
  const out = [];
  for (const l of lines) {
    try { out.push(JSON.parse(l)); } catch { /* 半行就算了 */ }
  }
  return out;
}

/** 群名缓存（同步，只读缓存；没有就叫调用方自己去 ensureNames）。 */
export function readNames() {
  try {
    const j = JSON.parse(fs.readFileSync(NAMES_FILE, 'utf8'));
    return (j && typeof j.groups === 'object' && j.groups) ? j.groups : {};
  } catch {
    return {};
  }
}

/** 群号 → 名字；没有缓存就退回群号本身。永远不抛。 */
export function nameOf(gid, names = readNames()) {
  return names[String(gid)] || String(gid);
}

/**
 * 去 NapCat 拉一次群名并写缓存。NapCat 挂了/超时就当没这回事（返回旧缓存）。
 * 只在 group-peek 里调 —— make-brief 是计划任务里的生成器，不碰网络。
 */
export async function ensureNames({ maxAgeMs = NAMES_MAX_AGE_MS } = {}) {
  const cached = readNames();
  try {
    const j = JSON.parse(fs.readFileSync(NAMES_FILE, 'utf8'));
    if (j && j.at && Date.now() - Number(j.at) < maxAgeMs && Object.keys(cached).length) return cached;
  } catch { /* 没有缓存，往下拉 */ }
  try {
    const token = fs.readFileSync(TOKEN_FILE, 'utf8').trim();
    const r = await fetch(`${NAPCAT}/get_group_list`, {
      method: 'POST',
      signal: AbortSignal.timeout(4000),
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
      body: '{}'
    });
    const j = await r.json();
    const groups = { ...cached };
    for (const g of (Array.isArray(j?.data) ? j.data : [])) {
      if (g && g.group_id !== undefined) groups[String(g.group_id)] = String(g.group_name ?? g.group_id);
    }
    fs.mkdirSync(GROUP_DIR, { recursive: true });
    fs.writeFileSync(NAMES_FILE, JSON.stringify({ at: Date.now(), groups }, null, 2) + '\n', 'utf8');
    return groups;
  } catch {
    return cached;
  }
}

/**
 * 最近一段时间的群消息，按时间正序。
 * @param {{minutes?: number, limit?: number, gid?: string|number, maxBytes?: number}} opts
 *   minutes=0 表示不限时间。
 */
export function tailMessages({ minutes = 60, limit = 25, gid = '', maxBytes } = {}) {
  const all = parseLines(tailLines(RAW_FILE, maxBytes));
  const cut = minutes > 0 ? Date.now() - minutes * 60 * 1000 : 0;
  let arr = all.filter(m => Number(m.ts) >= cut);
  if (gid !== '' && gid !== null && gid !== undefined) {
    arr = arr.filter(m => String(m.gid) === String(gid));
  }
  if (limit > 0 && arr.length > limit) arr = arr.slice(-limit);
  return arr;
}

const hhmm = ts => {
  const d = new Date(Number(ts) || 0);
  if (isNaN(d.getTime())) return '';
  return `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`;
};

/** 一句话的标记：她需要一眼看出哪些是冲她来的、哪些是她自己说的。 */
export function marksOf(m) {
  const out = [];
  if (m.self) out.push('我');
  if (m.addressed) out.push('@你');
  if (m.named && !m.addressed) out.push('点你名');
  if (m.replyToMe) out.push('回了你');
  if (m.atAll) out.push('@全体');
  return out;
}

/**
 * 一行人类可读的群消息。
 * @param {object} m   raw.jsonl 里的一条
 * @param {{names?: object, withGroup?: boolean, clip?: number}} opts
 */
export function format(m, { names = readNames(), withGroup = true, clip = 90 } = {}) {
  let text = String(m.text ?? '').replace(/\s+/g, ' ').trim();
  if (text.length > clip) text = text.slice(0, clip) + '…';
  const marks = marksOf(m);
  const tail = marks.length ? `（${marks.join('，')}）` : '';
  const who = m.self ? `${m.nick || '我'}` : (m.nick || m.qq || '?');
  const where = withGroup ? `[${nameOf(m.gid, names)}] ` : '';
  return `${hhmm(m.ts)} ${where}${who}：${text}${tail}`;
}

export { RAW_FILE, NAMES_FILE, hhmm };
