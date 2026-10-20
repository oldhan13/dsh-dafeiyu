// 群聊随听 —— 让她像人一样「在旁边听着群里说话」
//
// 为什么需要它：`dsh-onebot-qq` 的默认策略是 requireMention=true —— 群里没人 @ 她，
// 消息根本不会进她的会话。所以「浏览一遍群里的内容、自己决定要不要接话」必须有一条
// 独立于 agent 回合的通道。
//
// 数据来源：NapCat 的 httpClients（事件 POST 推送）→ 本文件的 HTTP 服务。
// 这条流不过滤，群里每条消息都会到；私聊也会到（一并忽略即可）。
//
// 她怎么反应（每 CHECK_EVERY_MS 看一次，有新消息才判断）：
//   SILENT       —— 什么都不做（默认，绝大多数时候）
//   REPLY: …     —— 发一句到群里（有冷却与配额）
//   NOTE: …      —— 记进 dafeiyu/group/<群号>.md（觉得有用/值得记的）
//
// 说话的门槛（2026-10-19 主人改的口径）：**只回 @ 她的人，和 @ 之后接着说的那场话。**
// 群里别人之间的聊天一律不接 —— 代码里先卡一道（没 @ 过 / 说话的人不在那场话里就丢掉 REPLY），
// 模型再判一道（话题换了也 SILENT）。NOTE 不受这个限制，值得记的照样记。
//
// 用法：
//   node watch.mjs            # 常驻
//   node watch.mjs --once     # 只做一次判断（真有新消息时才判断）
//   node watch.mjs --dry      # 判断但不发送、不写文件（调试用）

import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// ---------------------------------------------------------------- 配置
const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const GROUP_DIR = path.join(ROOT, 'dafeiyu', 'group');
const STATE_FILE = path.join(GROUP_DIR, 'state.json');
const RAW_FILE = path.join(GROUP_DIR, 'raw.jsonl');
const AGENTS = path.join(ROOT, 'AGENTS.md');

const PORT = 3078;
const HOST = '127.0.0.1';
const BOT_QQ = Number(process.env.DAFEIYU_BOT_QQ || 0);

const NAPCAT = 'http://127.0.0.1:3000';
const TOKEN = fs.readFileSync(path.join(process.env.USERPROFILE || process.env.HOME || '.', '.dsh', 'onebot-token.txt'), 'utf8').trim();
const KEY = fs.readFileSync(path.join(process.env.USERPROFILE || process.env.HOME || '.', '.dsh', 'siliconflow-key.txt'), 'utf8').trim();
// 群聊是闲聊，不该慢：用小而快的模型 + 很短的输出上限 + 硬超时。
// 想换回更强的模型就设环境变量 GROUP_MODEL。
const MODEL = process.env.GROUP_MODEL || 'Qwen/Qwen2.5-7B-Instruct';
const DECIDE_TIMEOUT_MS = 20000;
const MAX_OUT_TOKENS = 100;

const CHECK_EVERY_MS = 5 * 60 * 1000;   // 每 5 分钟看一次
const WINDOW_MS = 25 * 60 * 1000;       // 只看最近 25 分钟的群消息
const MAX_WINDOW = 40;                  // 窗口里最多保留多少条
const REPLY_GAP_MS = 10 * 60 * 1000;    // 同一个群两次发言至少间隔 10 分钟
const REPLY_PER_HOUR = 4;               // 每小时最多 4 句
const THREAD_MS = 15 * 60 * 1000;       // 被 @ 之后，这场对话再算「在跟她说话」15 分钟

// ---------------------------------------------------------------- 状态
function loadState() {
  try { return JSON.parse(fs.readFileSync(STATE_FILE, 'utf8')); } catch { return { replies: {}, lastCheck: 0, seen: 0 }; }
}
function saveState(s) {
  fs.mkdirSync(GROUP_DIR, { recursive: true });
  fs.writeFileSync(STATE_FILE, JSON.stringify(s, null, 2) + '\n', 'utf8');
}
function log(line) {
  const msg = `[${new Date().toISOString()}] ${line}`;
  fs.mkdirSync(GROUP_DIR, { recursive: true });
  fs.appendFileSync(path.join(GROUP_DIR, 'watch.log'), msg + '\n', 'utf8');
  console.log(msg);
}

// 内存窗口：group_id -> [{ts, qq, nick, text, addressed, atAll, named, replyToMe, replyToOther, self}]
// message_id -> {qq, nick}：群里有人引用回复时，靠它认出「他在回谁的话」。
const recentAuthors = new Map();
const RECENT_AUTHOR_MAX = 400;
const windows = new Map();

/** 这个群现在还在「跟她说」的那场话里吗？（直接读 state，不看内存窗口） */
function threadActive(gid) {
  try {
    const s = JSON.parse(fs.readFileSync(STATE_FILE, 'utf8'));
    const at = s.lastMention?.[gid] ?? 0;
    return at > 0 && Date.now() - at <= THREAD_MS;
  } catch { return false; }
}

// 有人 @ 她、或这场话还开着时，别等下一个 5 分钟的整点 —— 15 秒后就看一眼。
// 下限 60 秒一次，免得热闹的群把模型叫成筛子。
const QUICK_DELAY_MS = 15 * 1000;
const QUICK_MIN_GAP_MS = 60 * 1000;
let quickTimer = null;
let lastQuickAt = 0;
function scheduleQuick() {
  if (quickTimer) return;
  const wait = Math.max(QUICK_DELAY_MS, lastQuickAt + QUICK_MIN_GAP_MS - Date.now());
  quickTimer = setTimeout(() => {
    quickTimer = null;
    lastQuickAt = Date.now();
    runOnce().catch(e => log(`quick runOnce 失败: ${e.message}`));
  }, wait);
  if (quickTimer.unref) quickTimer.unref();
}

function pushEvent(ev) {
  const gid = String(ev.group_id);
  const segs = Array.isArray(ev.message) ? ev.message : [];
  const text = segs.filter(s => s.type === 'text').map(s => s.data?.text ?? '').join('').trim();
  const atIds = segs.filter(s => s.type === 'at').map(s => String(s.data?.qq ?? ''));
  const atMe = atIds.includes(String(BOT_QQ));
  const atAll = atIds.includes('all');
  const self = String(ev.user_id) === String(BOT_QQ) || ev.post_type === 'message_sent';
  // 引用回复：reply 段只带 id，作者要去作者表里反查（2026-10-19 加的）
  const replySeg = segs.find(s => s.type === 'reply');
  const replyToId = replySeg?.data?.id === undefined || replySeg?.data?.id === null ? '' : String(replySeg.data.id);
  const replyTo = replyToId === '' ? null : (recentAuthors.get(replyToId) ?? null);
  const replyToMe = replyTo !== null && String(replyTo.qq) === String(BOT_QQ);
  const replyToOther = replyTo !== null && !replyToMe;
  const item = {
    ts: Date.now(),
    qq: String(ev.user_id),
    nick: ev.sender?.card || ev.sender?.nickname || String(ev.user_id),
    text: text || (segs.some(s => s.type === 'image') ? '[图片]' : ''),
    addressed: atMe,
    atAll,
    // 只 @ 不写字的消息也算：她得知道「这一下是在点我」
    named: /大肥鱼|小鲸鱼|肥鱼|鲸鱼娘/.test(text),
    replyToId,
    replyToMe,
    replyToOther,
    replyToNick: replyTo?.nick ?? '',
    replyUnknown: replyToId !== '' && replyTo === null,
    self
  };
  // 先记作者（这一步要在过滤之前：被丢掉的纯表情消息也可能被别人引用）
  if (ev.message_id !== undefined && ev.message_id !== null && ev.message_id !== '') {
    recentAuthors.set(String(ev.message_id), { qq: item.qq, nick: item.nick });
    if (recentAuthors.size > RECENT_AUTHOR_MAX) {
      const oldest = recentAuthors.keys().next();
      if (!oldest.done) recentAuthors.delete(oldest.value);
    }
  }
  if (item.text === '' && !item.addressed) return item;   // 纯表情/文件等，先不进窗口
  if (item.text === '') item.text = '[@你]';
  const arr = windows.get(gid) ?? [];
  arr.push(item);
  while (arr.length > MAX_WINDOW) arr.shift();
  windows.set(gid, arr);
  try {
    fs.mkdirSync(GROUP_DIR, { recursive: true });
    fs.appendFileSync(RAW_FILE, JSON.stringify({ ...item, gid }) + '\n', 'utf8');
  } catch { /* 原始日志失败不影响判断 */ }
  // 2026-10-20 下午加：有人点她名 / @ 她 / 回她的话 —— 群会话会处理，但**心跳那条线看不见**
  // （它只读私聊和 relay）。她原话「我不怕漏，怕的是漏了没人告我」，所以顺手落一份到
  // dafeiyu/state/inbox.json，让心跳每次醒来先看一眼。只记"在说她"的，不记闲聊；
  // 最多留 20 条 —— 别做成第二个 QQ。
  if (!item.self && (item.addressed || item.named || item.replyToMe)) {
    try {
      const INBOX = path.join(GROUP_DIR, '..', 'state', 'inbox.json');
      fs.mkdirSync(path.dirname(INBOX), { recursive: true });
      let box = { items: [] };
      try { box = JSON.parse(fs.readFileSync(INBOX, 'utf8')); } catch { }
      const items = Array.isArray(box.items) ? box.items : [];
      const mid = String(ev.message_id ?? '');
      if (!items.some(x => x.kind === 'group' && x.messageId === mid && x.text === item.text)) {
        items.push({
          kind: 'group',
          gid,
          from: item.qq,
          nick: item.nick,
          text: item.text,
          messageId: mid,
          at: new Date().toISOString(),
          why: item.addressed ? 'at' : (item.replyToMe ? 'reply' : 'named')
        });
        fs.writeFileSync(INBOX, JSON.stringify({ items: items.slice(-20) }, null, 2) + '\n', 'utf8');
      }
    } catch { /* 写信箱失败不影响群里的判断 */ }
  }
  return item;
}

function recent(gid) {
  const arr = windows.get(gid) ?? [];
  const cut = Date.now() - WINDOW_MS;
  return arr.filter(x => x.ts >= cut);
}

// ---------------------------------------------------------------- 模型
async function decide(gid, items, { inThread = false, withWhom = [] } = {}) {
  const persona = fs.readFileSync(AGENTS, 'utf8');
  const notes = (() => {
    try { return fs.readFileSync(path.join(GROUP_DIR, `${gid}.md`), 'utf8').slice(-1500); } catch { return '（还没有记过）'; }
  })();
  const tags = (x) => [
    x.self ? '[你自己]' : '',
    x.addressed ? '[@你]' : '',
    x.atAll ? '[@全体]' : '',
    x.named ? '[点你名]' : '',
    x.replyToMe ? '[回你的话]' : '',
    x.replyToOther ? '[回' + (x.replyToNick || '别人') + '的话]' : '',
    x.replyUnknown ? '[引用了一条认不出的消息]' : ''
  ].join('');
  const chat = items.map(x => `${x.nick}(${x.qq})${tags(x)}: ${x.text}`).join('\n');
  const mode = inThread
    ? [
        `刚刚有人点过你的名（${withWhom.join('、') || '群里的人'}），那场话还没散。`,
        '这一轮你**只可以接着那场话回**；话题已经换掉、或者这些话不是在跟你说，就 SILENT。'
      ].join('\n')
    : [
        '这一轮**没有人点你**，也没有人在接着跟你说话 —— 你不能发言。',
        '只能输出 SILENT（或者 NOTE）。'
      ].join('\n');
  const prompt = [
    `你在群里（群号 ${gid}），你叫大肥鱼。下面是最近这一段的群聊，按时间顺序：`,
    chat,
    '',
    '你之前记下的这个群的笔记（节选）：',
    notes,
    '',
    mode,
    '',
    '规则：',
    '1. 默认 SILENT。群里别人之间的聊天不接 —— 没人点你，那些话不是给你的。',
    '2. 拿不准是不是在说你，就当不是。少接一句不亏，乱接一句把气氛搅了。',
    '2▸ 标签的意思：[@你]=直接叫你；[回你的话]=引用回复你；[点你名]=正文提到你的名字；',
    '   [@全体]=广播，不是在叫你；[回X的话]=这句是回应 X 的，不是给你的 —— 这种别接。',
    '3. 有人 [@你] 的那条由主会话回，别抢；你能接的是它之后紧接着的那几句。',
    '4. 群里的话短，一句到两句。不说教、不总结、不刷屏、不"作为一个AI"。',
    '5. 绝不提主人的私事、私聊内容、你们的约定。',
    '6. 有值得留下的东西（群里定的事、某个人的信息、一个梗的来由）就写 NOTE；闲聊不记。',
    '',
    '输出格式：一行，且只能是下面三种之一：',
    '  SILENT',
    '  REPLY: <你要说的那一句>',
    '  NOTE: <要记下的一句>'
  ].join('\n');

  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), DECIDE_TIMEOUT_MS);
  let r;
  try {
    r = await fetch('https://api.siliconflow.cn/v1/chat/completions', {
      method: 'POST',
      signal: ctrl.signal,
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${KEY}` },
      body: JSON.stringify({
        model: MODEL,
        temperature: 0.9,
        max_tokens: MAX_OUT_TOKENS,
        messages: [
          { role: 'system', content: persona },
          { role: 'user', content: prompt }
        ]
      })
    });
  }
  finally { clearTimeout(timer); }
  if (!r.ok) throw new Error(`llm ${r.status} ${await r.text()}`);
  const j = await r.json();
  return (j.choices?.[0]?.message?.content ?? '').trim();
}

// ---------------------------------------------------------------- 动作
async function sendGroup(gid, text) {
  const r = await fetch(`${NAPCAT}/send_group_msg`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${TOKEN}` },
    body: JSON.stringify({ group_id: Number(gid), message: [{ type: 'text', data: { text } }] })
  });
  const j = await r.json().catch(() => ({}));
  if (j.status !== 'ok') throw new Error(`send failed ${JSON.stringify(j).slice(0, 200)}`);
  return j.data?.message_id;
}

function appendNote(gid, text) {
  fs.mkdirSync(GROUP_DIR, { recursive: true });
  const file = path.join(GROUP_DIR, `${gid}.md`);
  const head = fs.existsSync(file) ? '' : `# 群 ${gid} · 我记下来的\n\n`;
  fs.appendFileSync(file, `${head}- ${new Date().toISOString()} ${text}\n`, 'utf8');
}

/**
 * 说话的两道闸（2026-10-19 主人改的口径）：
 *   1. 必须有人在这 15 分钟里点过她的名（@ 或者叫名字）
 *   2. 眼下这几句得是「跟她说的话」—— 点她名的人、叫她名字的人，或者就是她自己
 * 两道都过才允许 REPLY。NOTE 不受限，值得记的照样记。
 */
function replyGate({ inThread, fresh, withWhom }) {
  if (!inThread) return { ok: false, why: '没人在 15 分钟内点过她' };
  const mine = fresh.filter(x => !x.self);
  if (mine.length === 0) return { ok: false, why: '这几条都是她自己说的' };
  // 全是「在回别人的话」⇒ 那是别人之间的一场对话，一句都别插
  if (mine.every(x => x.replyToOther && !x.addressed && !x.named)) return { ok: false, why: '这几句都在回别人' };
  const engaged = mine.some(x => x.addressed || x.replyToMe || x.named || withWhom.includes(x.qq));
  if (!engaged) return { ok: false, why: '这几句不是跟她说的' };
  return { ok: true };
}

function allowedToReply(state, gid) {
  const now = Date.now();
  const list = (state.replies?.[gid] ?? []).filter(t => now - t < 60 * 60 * 1000);
  state.replies = state.replies ?? {};
  state.replies[gid] = list;
  if (list.length >= REPLY_PER_HOUR) return { ok: false, why: `本小时已说 ${list.length} 句` };
  const last = list[list.length - 1];
  if (last && now - last < REPLY_GAP_MS) return { ok: false, why: `刚说过 ${Math.round((now - last) / 60000)} 分钟` };
  return { ok: true };
}

/** 模型偶尔会把 </think> 之类的推理标签一起吐出来；这里把它剥掉，再从中找一个合法指令行。 */
function parseDirective(out) {
  const clean = String(out ?? '').replace(/<\/?think>/gi, '').replace(/\r/g, '');
  const lines = clean.split('\n').map(s => s.trim()).filter(Boolean);
  for (const line of lines) {
    if (/^(SILENT|REPLY\s*[:：]|NOTE\s*[:：])/i.test(line)) return line;
  }
  // 没有独立成行的指令时，退一步看全文是否只是想沉默
  if (/silent/i.test(clean) && !/reply\s*[:：]/i.test(clean) && !/note\s*[:：]/i.test(clean)) return 'SILENT';
  return lines[0] ?? '';
}

async function runOnce({ dry = false } = {}) {
  const state = loadState();
  const groups = [...windows.keys()].filter(gid => recent(gid).length > 0);
  let acted = 0;

  for (const gid of groups) {
    const items = recent(gid);
    const fresh = items.filter(x => x.ts > (state.lastCheck ?? 0));
    if (fresh.length === 0) continue;

    // 有人 @ 她：那条已经由 agent 会话处理，这里不重复接话。
    // 但要把「这场话」记下来 —— @ 之后紧接着的几句，还算是跟她在说，她接得上。
    const mentions = fresh.filter(x => x.addressed);
    if (mentions.length > 0) {
      state.lastMention = state.lastMention ?? {};
      state.threadWith = state.threadWith ?? {};
      const at = Math.max(...mentions.map(x => x.ts));
      if (at > (state.lastMention[gid] ?? 0)) {
        state.lastMention[gid] = at;
        state.threadWith[gid] = [...new Set(mentions.map(x => x.qq))];
      }
      saveState(state);
      log(`[${gid}] 有 @，交给主会话回（本机不抢）；之后 ${THREAD_MS / 60000} 分钟内这场话还接得上`);
      continue;
    }

    // 硬门槛：没人在 THREAD_MS 内点过她 ⇒ 不准开口（仍可以让模型记 NOTE）
    const mentionAt = state.lastMention?.[gid] ?? 0;
    const inThread = mentionAt > 0 && Date.now() - mentionAt <= THREAD_MS;
    const withWhom = state.threadWith?.[gid] ?? [];

    let out;
    try { out = await decide(gid, items, { inThread, withWhom }); }
    catch (e) { log(`[${gid}] decide 失败: ${e.message}`); continue; }
    if (!out) continue;

    const line = parseDirective(out);
    if (line === '') continue;
    const threadNote = inThread ? `，@ 后 ${Math.round((Date.now() - mentionAt) / 60000)} 分钟` : '，没人点她';
    if (/^SILENT$/i.test(line)) { log(`[${gid}] silent（新 ${fresh.length} 条${threadNote}）`); continue; }

    const reply = /^REPLY\s*[:：]\s*(.+)$/i.exec(line);
    if (reply) {
      const text = reply[1].trim().slice(0, 300);
      // 先过「该不该说」这两道闸，再看配额
      const speak = replyGate({ inThread, fresh, withWhom });
      if (!speak.ok) { log(`[${gid}] 话咽回去了（${speak.why}）: ${text}`); continue; }
      const gate = allowedToReply(state, gid);
      if (!gate.ok) { log(`[${gid}] 想说但克制了（${gate.why}）: ${text}`); continue; }
      if (dry) { log(`[${gid}] DRY 想回: ${text}`); continue; }
      try {
        const mid = await sendGroup(gid, text);
        state.replies[gid] = [...(state.replies[gid] ?? []), Date.now()].slice(-20);
        saveState(state);
        const arr = windows.get(gid) ?? [];
        arr.push({ ts: Date.now(), qq: BOT_QQ, nick: '大肥鱼', text, addressed: false, atAll: false, named: false, replyToMe: false, replyToOther: false, self: true });
        log(`[${gid}] 回了(${mid}): ${text}`);
        acted++;
      } catch (e) { log(`[${gid}] 发送失败: ${e.message}`); }
      continue;
    }

    const note = /^NOTE\s*[:：]\s*(.+)$/i.exec(line);
    if (note) {
      const text = note[1].trim().slice(0, 300);
      if (dry) { log(`[${gid}] DRY 想记: ${text}`); continue; }
      appendNote(gid, text);
      log(`[${gid}] 记下: ${text}`);
      acted++;
      continue;
    }

    log(`[${gid}] 输出无法解析: ${line}`);
  }

  state.lastCheck = Date.now();
  if (!dry) saveState(state);
  return acted;
}

// ---------------------------------------------------------------- HTTP 入口
function startServer() {
  const server = http.createServer((req, res) => {
    if (req.method !== 'POST') { res.writeHead(405).end(); return; }
    const auth = req.headers.authorization ?? '';
    // NapCat 的 httpClient 是裸 token（不带 Bearer），别的实现可能带 —— 两种都收。
    const authOk = TOKEN === '' || auth === `Bearer ${TOKEN}` || auth === TOKEN;
    if (!authOk) { res.writeHead(401).end(); return; }
    let body = '';
    req.on('data', c => { body += c; });
    req.on('end', () => {
      res.writeHead(204).end();
      try {
        const ev = JSON.parse(body);
        if (ev?.message_type === 'group' && (ev?.post_type === 'message' || ev?.post_type === 'message_sent')) {
          const item = pushEvent(ev);
          const gid = String(ev.group_id);
          // 点了她、或者这场话本来就没散 —— 值得马上看一眼（不然闲聊里的接话会慢 5 分钟）
          if (item?.addressed || threadActive(gid)) scheduleQuick();
        }
      } catch { /* 忽略非 JSON */ }
    });
  });
  server.listen(PORT, HOST, () => log(`group watch 在听 http://${HOST}:${PORT}/ （等 NapCat 推送事件）`));
  return server;
}

// ---------------------------------------------------------------- main
const once = process.argv.includes('--once');
const dry = process.argv.includes('--dry');
// 被 import 时（单元测试）不启服务、不跑循环；只有直接执行才当主程序
const isMain = Boolean(process.argv[1]) && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);

if (isMain && once) {
  // 单次模式：不建监听，只用 raw.jsonl 里已有的最近记录判断（便于调试）
  try {
    const lines = fs.readFileSync(RAW_FILE, 'utf8').split('\n').filter(Boolean).slice(-60);
    for (const l of lines) {
      const x = JSON.parse(l);
      if (x.ts < Date.now() - WINDOW_MS) continue;
      const arr = windows.get(String(x.gid)) ?? [];
      arr.push(x);
      windows.set(String(x.gid), arr);
    }
  } catch { /* 没有历史 */ }
  const n = await runOnce({ dry });
  process.exit(n >= 0 ? 0 : 1);
}

if (isMain) {
  startServer();
  const timer = setInterval(() => { runOnce().catch(e => log(`runOnce 失败: ${e.message}`)); }, CHECK_EVERY_MS);
  process.on('SIGINT', () => { clearInterval(timer); process.exit(0); });
}

export { replyGate, parseDirective };

