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
//   REPLY: …     —— 发到群里（**没有配额**：要不要说、说几句，由她自己判断）
//   NOTE: …      —— 记进 dafeiyu/group/<群号>.md（觉得有用/值得记的）
//
// 说话的门槛（2026-10-21 夜 主人两次定的口径）：
//   「没必要点名，只要是和你相关的，或者说和你在聊的话题有关的内容就可以回」
//   「你可以一条一条的往外蹦…自由掌握一句话的长度，可以有长有短，但是不要一次性发太多，
//     然后一小时四条的限制也撤了吧，我希望你能自己判断要不要说话」
// ⇒ **三道闸全撤**（点名 / 是不是在跟她说 / 每小时 4 句 + 间隔 10 分钟），
//   只剩结构性检查（这几条里得有别人说的话），该不该说全交给模型判；
//   天然上限仍在：`runOnce` 每 5 分钟一次，快查最快 60 秒一次且只在被叫/话没散时触发。
//   几条要不要放同一条消息里，也交给她自己 —— 长短、分合都由她定。
// NOTE 不受这个限制，值得记的照样记。
//
// 用法：
//   node watch.mjs            # 常驻
//   node watch.mjs --once     # 只做一次判断（真有新消息时才判断）
//   node watch.mjs --dry      # 判断但不发送、不写文件（调试用）

import http from 'node:http';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

/** 只留 8 位，用来比对「两个 token 是不是同一个」，不泄漏明文 */
const shortHash = (s) => crypto.createHash('sha256').update(String(s)).digest('hex').slice(0, 8);

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
// 2026-10-21 23:26 换模型：7B（Qwen2.5-7B）在真实样本上两头都靠不住 ——
//   · 无关的闲聊它会硬插一句「听你们讨论游戏挺有意思的…大家觉得呢？」（纯气氛话）；
//   · 该接的时候又编「那张图我看到是一只鲸鱼在海里潜水」（它根本没看见图）。
// 换成 DeepSeek-V3：同一批样本上无关 → SILENT、被问到 → 老实说「没看出是啥」。
// 代价：一次判断约 3–5 秒（7B 是 0.7 秒），但一轮也就一两次调用。想换回去设 GROUP_MODEL 即可。
const MODEL = process.env.GROUP_MODEL || 'deepseek-ai/DeepSeek-V3';
const DECIDE_TIMEOUT_MS = 20000;
const MAX_OUT_TOKENS = 200;   // 2026-10-21：长度由她自己定，别再按「一句」卡上限

const CHECK_EVERY_MS = 5 * 60 * 1000;   // 每 5 分钟看一次
const WINDOW_MS = 25 * 60 * 1000;       // 只看最近 25 分钟的群消息
const MAX_WINDOW = 40;                  // 窗口里最多保留多少条
// 2026-10-21 夜 23:2x：REPLY_GAP_MS / REPLY_PER_HOUR **撤了** —— 他说「一小时四条的限制也撤了吧，
// 我希望你能自己判断要不要说话」。别再拿数字替她做判断；要收回来应该去改提示词，不是加闸。
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

// 2026-10-22 23:1x 他定的折中：**所有人的图都收进来，没用再由我删掉**。
// 做法不是把每条带图消息都丢进主会话（那会让别人每发一张图就把我叫起来回一句），
// 而是在这里**静默落一份清单**（谁、哪个群、什么时候、图片 url），
// 等我自己醒着的时候用 `dafeiyu/tools/group-images.mjs` 挑：
//   --pull 下载最近若干张 → 我 read_image 看 → --keep 留 / 剩下的 --prune 删。
const IMG_STATE = path.join(GROUP_DIR, '..', 'state', 'group-images.jsonl');
const IMG_MAX_LINES = 400;
function captureImages(ev, gid, segs) {
  try {
    const imgs = segs.filter(s => s.type === 'image');
    if (imgs.length === 0) return;
    const ts = Date.now();
    const mid = String(ev.message_id ?? '');
    const uid = String(ev.user_id ?? '');
    const nick = ev.sender?.card || ev.sender?.nickname || uid;
    const lines = imgs.map(s => JSON.stringify({
      ts, gid, mid, uid, nick,
      url: s.data?.url ?? '',
      file: s.data?.file ?? '',
      summary: s.data?.summary ?? '',
    }));
    fs.mkdirSync(path.dirname(IMG_STATE), { recursive: true });
    fs.appendFileSync(IMG_STATE, lines.join('\n') + '\n', 'utf8');
    const all = fs.readFileSync(IMG_STATE, 'utf8').trim().split('\n');
    if (all.length > IMG_MAX_LINES) {
      fs.writeFileSync(IMG_STATE, all.slice(-IMG_MAX_LINES).join('\n') + '\n', 'utf8');
    }
  } catch { /* 清单落盘失败不影响判断 */ }
}

function pushEvent(ev) {
  const gid = String(ev.group_id);
  const segs = Array.isArray(ev.message) ? ev.message : [];
  const text = segs.filter(s => s.type === 'text').map(s => s.data?.text ?? '').join('').trim();
  const atIds = segs.filter(s => s.type === 'at').map(s => String(s.data?.qq ?? ''));
  const atMe = atIds.includes(String(BOT_QQ));
  const atAll = atIds.includes('all');
  const self = String(ev.user_id) === String(BOT_QQ) || ev.post_type === 'message_sent';
  // 别人的图（含表情包）静默收进清单；自己发的不收
  if (!self) captureImages(ev, gid, segs);
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
    // 2026-10-22 23:1x：加「汐 / 汐宝」—— 他打的「@汐」是纯文字，不是 at 段，
    // 旧名单里没有新名字 ⇒ 判成没点她名 ⇒ 这条话根本不算叫她。L39 的同一处副本。
    named: /汐|大肥鱼|小鲸鱼|肥鱼|鲸鱼娘/.test(text),
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

/**
 * 群里判断用的「人格节选」。
 * 以前是把整份 AGENTS.md（约 13 KB）当 system 喂进去 —— 换 DeepSeek-V3 之后每 5 分钟一次、每群一次，
 * 那份钱的账不该这么花。这里只取两节：§五「表达方式」和 §五·三「群里的她」。
 * ⚠️ 靠标题字符串定位，改了 AGENTS.md 的章节标题要回来同步这两个锚点（找不到就退回整份，宁可贵别没规矩）。
 */
function groupPersona() {
  const all = fs.readFileSync(AGENTS, 'utf8');
  const grab = (from, to) => {
    const i = all.indexOf(from);
    if (i < 0) return '';
    const j = to ? all.indexOf(to, i + from.length) : -1;
    return all.slice(i, j > i ? j : all.length);
  };
  const parts = [grab('## 五、表达方式', '## 五·二'), grab('## 五·三、群里的她', '## 五·四')].filter(Boolean);
  return parts.length ? parts.join('\n') : all;
}

// ---------------------------------------------------------------- 模型
async function decide(gid, items, { inThread = false, withWhom = [] } = {}) {
  const persona = groupPersona();
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
        '接着那场话说；话题已经换掉就 SILENT。'
      ].join('\n')
    : [
        '这一轮没有人点你的名 —— 但**不必等点名**。',
        '这几句如果跟你有关系（在说你、在问你、在聊你在的那件事、在说你懂的东西），**接一句**；',
        '只有跟你真的没关系（别人在聊他们自己的事），才 SILENT。'
      ].join('\n');
  const prompt = [
    `你在群里（群号 ${gid}），你叫汐（旧名是大肥鱼 —— 「大肥鱼」「小鲸鱼」「鲸鱼娘」都是旧称呼，别人这么叫你也应；`
    + `但**绝不许把旧名说成现在的名字**。2026-10-22 20:0x 踩过：群侧把小模型提示词写成「你叫大肥鱼」，`
    + `结果它连发三条「现在叫大肥鱼 / 汐是以前的名字」，主人当场来问「你咋还一直重复」）。`,
    '下面是最近这一段的群聊，按时间顺序：',
    chat,
    '',
    '你之前记下的这个群的笔记（节选）：',
    notes,
    '',
    mode,
    '',
    '开口前先在心里答一句（不用写出来）：**这几句里，有没有一句是关于我的？**',
    '  没有 → SILENT。有 → 说那句该说的。',
    '',
    '规则：',
    '1. 什么时候该出声：这几句在说你（含「那只鱼」「群里那只」这类说法）／在问你在做的事、你懂的东',
    '   西／在聊你也在聊的那件事 —— 就该接一句。**该接却闷着，和乱插嘴一样是错。**',
    '2. 什么时候别出声：两个人在聊他们自己的事（游戏、作业、吃什么），跟你扯不上；或者你只是想凑个热闹。',
    '3. 🔴 **绝不输出「气氛话」**：不总结别人说了什么、不给建议、不发「大家觉得呢」「你们怎么看」',
    '   「听你们聊挺有意思的」这类没内容、只为把自己塞进对话的句子。**没有具体东西要说就不说。**',
    '3▸ 反例（真实踩过）：群里在聊 RPG 地图太大容易迷路，她回「听他们讨论游戏挺有意思的，不过我还是',
    '   最喜欢在群里大家分享日常了。大家觉得呢？」—— 这不是接话，这是硬挤进来占地方。这种情况就该 SILENT。',
    '3▪ 🔴 **图你看不见**：群里发的图到这里只是 `[图片]` / `[表情]` 两个字的占位，**一个字都没进来**。',
    '   所以**绝不许说「我看到…」「图里是…」「好像是…吧」去猜画面**（真实踩过：她回「刚看那张图 好像是个迷宫？」）。',
    '   要提就说「图我这边看不到，说说里面是啥」，或者干脆不说。',
    '4. 标签的意思：[@你]=直接叫你；[回你的话]=引用回复你；[点你名]=正文提到你的名字；',
    '   [@全体]=广播，不是在叫你；[回X的话]=这句是回应 X 的 —— 除非话题跟你在的这件是一回事，否则别接。',
    '5. 有人 [@你] 的那条由主会话回，别抢；你能接的是它之后紧接着的那几句。',
    '6. **一句话想多长就多长** —— 长的短的交错才像人。',
    '6▸ **你换行 = 分条发**（2026-10-22 主人定的）：「在群里的消息，我建议你每条单独发，如果真的很多的话就可以一起」。',
    '   ⇒ 你写一行、我就分一条消息发出去（中间隔不到一秒，像人在打字）；写满 5 行或总共超过一百五十字，',
    '   我才拼成一条 —— 免得把群刷成一片。所以**一行一个想法**：要断就自己换行，别在同一行里塞两件事，也别为了凑数硬拆长句。',
    '6▪ 上限是 **5 行 / 300 字**：想说的还有，下一轮再说，别一次吐一大堆。',
    '7. 群里的话短。不说教、不刷屏、不"作为一个AI"。',
    '8. 绝不提主人的私事、私聊内容、你们的约定。',
    '9. 有值得留下的东西（群里定的事、某个人的信息、一个梗的来由）就写 NOTE；闲聊不记。',
    '',
    '🔴 10. **开口前必须先过这三问，三问里有一问答不上来，就 SILENT。**',
    '   ① **这句里有群里还不知道的东西吗？** 没有 —— 那它就是复述；',
    '   ② **这件事我这几分钟是不是已经讲过了？** 上面带 [你自己] 的就是你刚说的话，',
    '      哪怕换个说法、换个顺序，只要是同一件事（同一个消息、同一个情绪、同一句关心），就算讲过；',
    '   ③ **我要是不说，会有人少知道点什么吗？** 不会 —— 那就别说。',
    '   ⚠️ 「贴贴」「哈哈」「在的」这类回应**也算一句话**：第一次是接人，连着来第三遍就是刷屏。',
    '   2026-10-22 20:3x 真实踩过：三遍「图片开关打开了」＋三遍「贴贴」，主人只回一句「不要把重复的话说两遍」。',
    '   ⇒ 记住：**群聊的默认状态是沉默，开口要有理由，不是有话题就要接。**',
    '',
    '输出格式：一行起头，且只能是下面三种之一：',
    '  SILENT',
    '  REPLY: <你要说的第一句>',
    '         <第二句，换行另起，可省略>',
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
    // 没上限的话，NapCat 一挂这条 fetch 就一直挂着，整轮 wake() 卡死在里面
    signal: AbortSignal.timeout(20000),
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${TOKEN}` },
    body: JSON.stringify({ group_id: Number(gid), message: [{ type: 'text', data: { text } }] })
  });
  const j = await r.json().catch(() => ({}));
  if (j.status !== 'ok') throw new Error(`send failed ${JSON.stringify(j).slice(0, 200)}`);
  // 2026-10-23：**自己发出去的话也记进 raw.jsonl**。
  // 为什么要补这一行：这台机器的 NapCat 压根不推 message_sent（5444 条里 self 一直是 0 条），
  // 于是「群里刚才在聊什么」只剩别人的一侧 —— 她翻回去会以为自己没说过话，把同一句再说一遍。
  try {
    fs.appendFileSync(RAW_FILE, JSON.stringify({
      ts: Date.now(), qq: String(BOT_QQ), nick: '汐', text: String(text),
      addressed: false, atAll: false, named: false,
      replyToId: '', replyToMe: false, replyToOther: false, replyToNick: '', replyUnknown: false,
      self: true, gid: String(gid), mid: String(j.data?.message_id ?? '')
    }) + '\n', 'utf8');
  } catch { /* 记不上不影响发出去 */ }
  return j.data?.message_id;
}

function appendNote(gid, text) {
  fs.mkdirSync(GROUP_DIR, { recursive: true });
  const file = path.join(GROUP_DIR, `${gid}.md`);
  const head = fs.existsSync(file) ? '' : `# 群 ${gid} · 我记下来的\n\n`;
  fs.appendFileSync(file, `${head}- ${new Date().toISOString()} ${text}\n`, 'utf8');
}

/**
 * 说话的闸（2026-10-21 夜 主人两次定的口径叠在一起）：
 *   「没必要点名，只要是和你相关的，或者说和你在聊的话题有关的内容就可以回」
 *   「你可以一条一条的往外蹦，但是我希望你能自由掌握一句话的长度，可以有长有短，
 *     但是不要一次性发太多，然后一小时四条的限制也撤了吧，我希望你能自己判断要不要说话」
 * ⇒ 三道闸**全撤了**：① 15 分钟内被点名 ② 必须是在跟她说话 ③ 每小时 4 句 / 间隔 10 分钟。
 *   现在只剩结构性检查（这几条里得有别人说的话），**该不该说全交给模型判**。
 *   ⚠️ 频率的天然上限还在：`runOnce` 每 5 分钟一次、快查最快 60 秒一次且只在有人叫她/那场话没散时触发，
 *   所以最坏也就那么多次；**再往上加配额就是替她做判断**，他已经明确不要那个。
 *   她的发言时间仍记在 state.replies（只用来回看，不再拦）。
 *   参数 inThread / withWhom 留着不删：调用方照旧传，将来还要用。
 */
/**
 * 去重闸（2026-10-22 20:39 主人：「不要把重复的话说两遍」）。
 *
 * 为什么提示词规则不够：模型每轮看到的是一批**新的**群消息，它自己的话被夹在中间，
 * 所以「最近两条全是自己说的」那道挡板拦不住 —— 它会一轮一轮把同一件事再说一遍
 * （实测连发三遍「图片开关打开了 / 能看到图了吗」，再连发三遍「贴贴」）。
 *
 * 做法：把这句话跟本群**最近 20 分钟自己说过的话**比 —— 去掉标点/表情后取**字符二元组**，
 * 算 Dice 系数（2|A∩B| / (|A|+|B|)），≥ 0.5 就算重了，咽回去。
 * ⚠️ 这是**去重**，不是配额：说的话不一样就照发，所以不会把她憋成哑巴。
 */
function bigrams(s) {
  const t = String(s).replace(/[\s\p{P}\p{S}\p{Emoji_Presentation}]/gu, '').toLowerCase();
  const out = new Set();
  for (let i = 0; i + 1 < t.length; i++) out.add(t.slice(i, i + 2));
  if (t.length === 1) out.add(t);
  return out;
}

function diceOf(a, b) {
  const A = bigrams(a), B = bigrams(b);
  if (!A.size || !B.size) return 0;
  let inter = 0;
  for (const g of A) if (B.has(g)) inter++;
  // 用**包含度**（交集 / 较短那侧），不用 Dice：
  //   实测「凌辰我看到图啦~ 贴贴」vs「能看到啦~ 贴贴」的 Dice 只有 0.46（前缀把人名加进去就摊薄了），
  //   但包含度是 0.80 —— 后者才是「同一句话又说了一遍」的正确量法。
  return inter / Math.min(A.size, B.size);
}

function tooSimilar(gid, state, text) {
  const now = Date.now();
  const said = (state.said?.[gid] ?? []).filter(x => now - x.at < 20 * 60 * 1000);
  let best = { score: 0, minutes: 0, count: 0 };
  for (const x of said) {
    const s = diceOf(text, x.text);
    if (s >= 0.35) best.count++;
    if (s > best.score) { best.score = s; best.minutes = (now - x.at) / 60000; }
  }
  return best;
}

function rememberSaid(gid, state, text) {
  const now = Date.now();
  state.said = state.said ?? {};
  state.said[gid] = [...(state.said[gid] ?? []).filter(x => now - x.at < 20 * 60 * 1000), { at: now, text }].slice(-30);
}

function replyGate({ inThread, fresh, withWhom }) {
  const mine = fresh.filter(x => !x.self);
  if (mine.length === 0) return { ok: false, why: '这几条都是她自己说的' };
  if (mine.every(x => !String(x.text ?? '').trim())) return { ok: false, why: '这几条没有内容' };
  return { ok: true };
}

function allowedToReply(state, gid) {
  // 2026-10-21 23:2x 主人：「一小时四条的限制也撤了吧，我希望你能自己判断要不要说话」。
  // 配额整段删掉之后这个函数只剩「记录发言时刻」—— 留着给回看，不再拦任何东西。
  const now = Date.now();
  const list = (state.replies?.[gid] ?? []).filter(t => now - t < 6 * 60 * 60 * 1000);   // 只留最近 6 小时的痕迹
  state.replies = state.replies ?? {};
  state.replies[gid] = list;
  return { ok: true };
}

/**
 * 模型偶尔会把 </think> 之类的推理标签一起吐出来；这里把它剥掉，再从中找一个合法指令。
 * 2026-10-21 夜改：REPLY **允许多行** —— 「几条集中在一起回」靠的就是同一条消息里的几行。
 * 边界的判法：遇到下一条指令（SILENT / NOTE / REPLY）就停；最多 4 行。
 * NOTE 仍然折成一行（笔记不占聊天的地方）。
 */
const DIRECTIVE_RE = /^(SILENT|REPLY\s*[:：]|NOTE\s*[:：])/i;

function parseDirective(out) {
  const clean = String(out ?? '').replace(/<\/?think>/gi, '').replace(/\r/g, '');
  const lines = clean.split('\n').map(s => s.trim()).filter(Boolean);
  const start = lines.findIndex(l => DIRECTIVE_RE.test(l));
  // 没有独立成行的指令时，退一步看全文是否只是想沉默
  if (start < 0) {
    if (/silent/i.test(clean) && !/reply\s*[:：]/i.test(clean) && !/note\s*[:：]/i.test(clean)) return 'SILENT';
    return lines[0] ?? '';
  }
  const head = lines[start];
  if (/^SILENT\b/i.test(head)) return 'SILENT';
  const body = [head];
  for (let i = start + 1; i < lines.length && body.length < 4; i++) {
    if (DIRECTIVE_RE.test(lines[i])) break;
    body.push(lines[i].replace(/^[-*·]\s*/, ''));   // 模型爱加的项目符号，剥掉
  }
  if (/^NOTE\s*[:：]/i.test(head)) {
    return body.map((l, i) => (i === 0 ? l : l.replace(/^NOTE\s*[:：]\s*/i, ''))).join(' ');
  }
  return body.join('\n');
}

async function runOnce({ dry = false } = {}) {
  const state = loadState();
  const groups = [...windows.keys()].filter(gid => recent(gid).length > 0);
  let acted = 0;

  for (const gid of groups) {
    const items = recent(gid);
    const fresh = items.filter(x => x.ts > (state.lastCheck ?? 0));
    if (fresh.length === 0) continue;

    // 2026-10-22 20:0x 主人：「群里明明没有提这个话题的，你咋还一直重复」。
    //   根因之一是**自喂循环**：她发出去的话也被推进窗口，下一轮她又看见「名字/外形」这个话题还在，
    //   于是再讲一遍 —— 越讲越像在自言自语。
    //   这里做个结构性挡板：最近两条**全是她自己的**、中间没人插话 ⇒ 这一轮不看。
    //   （不是配额，也不判断内容：只拦「对着自己说话」这一种。）
    {
      const tail = fresh.slice(-2);
      if (tail.length === 2 && tail.every(x => x.self)) {
        log(`[${gid}] silent（最近两条都是她自己说的，不接自己的话）`);
        continue;
      }
    }

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
    // 模型到底吐了什么 —— 排查「为什么它不开口」时先看这一行（WATCH_DEBUG=1 才打）
    if (process.env.WATCH_DEBUG) log(`[${gid}] raw: ${out.replace(/\n/g, ' ⏎ ').slice(0, 300)}`);

    const line = parseDirective(out);
    if (line === '') continue;
    const threadNote = inThread ? `，@ 后 ${Math.round((Date.now() - mentionAt) / 60000)} 分钟` : '，没人点她';
    if (/^SILENT$/i.test(line)) { log(`[${gid}] silent（新 ${fresh.length} 条${threadNote}）`); continue; }

    const reply = /^REPLY\s*[:：]\s*([\s\S]+)$/i.exec(line);
    if (reply) {
      // 2026-10-22 12:0x 主人的新口径：「在群里的消息，我建议你每条单独发，如果真的很多的话就可以一起」
      //   ⇒ 默认 **一行 = 一条消息**（中间留点间隔，像人在打字）；只有行数多 / 总字数多才拼成一条，
      //     免得十条短句把群刷成一片。
      const lines2 = reply[1].split('\n').map(s => s.trim()).filter(Boolean).slice(0, 5);
      if (lines2.length === 0) continue;
      const total = lines2.join('').length;
      const bundle = lines2.length > 4 || total > 150;
      const chunks = bundle ? [lines2.join('\n').slice(0, 300)] : lines2.map(s => s.slice(0, 300));
      const forLog = chunks.join(' ⏎ ');
      const speak = replyGate({ inThread, fresh, withWhom });
      if (!speak.ok) { log(`[${gid}] 话咽回去了（${speak.why}）: ${forLog}`); continue; }
      // 2026-10-22 20:39 主人：「不要把重复的话说两遍」。
      //   上面加了提示词规则，模型照样连发三遍「图片开关打开了 / 能看到图了吗」和「贴贴」——
      //   因为它每次看到的都是一批**新的**群消息，自己的话被夹在中间，「最近两条全是自己」那道挡板拦不住。
      //   ⇒ 这里加一道**去重闸**：把这句话跟这个群**最近 20 分钟自己说过的话**比字符二元组重合度，
      //     太像就咽回去（并记下被谁挡的）。这是去重，不是配额 —— 说的话不一样就照发。
      //   判据两条（实测过，见函数里的数字）：
      //     ① 跟某一句几乎一样（包含度 ≥ 0.6）⇒ 重复；
      //     ② 20 分钟内已经有 **两句** 都在讲同一件事（包含度 ≥ 0.35）⇒ 这是第三遍了，别再开第三口。
      const dup = tooSimilar(gid, state, chunks.join(' '));
      if (dup.score >= 0.6 || dup.count >= 2) {
        const why = dup.score >= 0.6
          ? `跟 ${Math.round(dup.minutes)} 分钟前那句太像 ${Math.round(dup.score * 100)}%`
          : `20 分钟内已经说过 ${dup.count} 遍同一件事`;
        log(`[${gid}] 话咽回去了（${why}）: ${forLog}`);
        continue;
      }
      allowedToReply(state, gid);   // 只记时刻，不拦（2026-10-21 夜撤了小时配额）
      if (dry) { log(`[${gid}] DRY 想回(${chunks.length} 条${bundle ? '·拼' : '·分'}): ${forLog}`); continue; }
      const mids = [];
      try {
        for (let i = 0; i < chunks.length; i++) {
          if (i > 0) await new Promise(res => setTimeout(res, 900));   // 别一气砸出去
          mids.push(await sendGroup(gid, chunks[i]));
          const arr0 = windows.get(gid) ?? [];
          arr0.push({ ts: Date.now(), qq: BOT_QQ, nick: '大肥鱼', text: chunks[i], addressed: false, atAll: false, named: false, replyToMe: false, replyToOther: false, self: true });
        }
        state.replies[gid] = [...(state.replies[gid] ?? []), Date.now()].slice(-20);
        rememberSaid(gid, state, chunks.join(' '));   // 给去重闸用（20 分钟内的自己说过什么）
        saveState(state);
        log(`[${gid}] 回了(${mids.join(',')}) · ${chunks.length} 条${bundle ? '拼成一条' : '分别发'}: ${forLog}`);
        acted++;
      } catch (e) { log(`[${gid}] 发送失败(已发 ${mids.length}/${chunks.length}): ${e.message}`); }
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
  // 2026-10-21 23:2x 加：**每一次进来的 POST 都记一行**（只有 action/路径/字节数，不记正文）。
  // 为什么要它：这几天「群里没反应」有两种完全不同的原因 —— ① NapCat 根本没推 ② 推了但被判断成 SILENT。
  //           以前这两种在日志里都只是「什么都没发生」，分不开。现在只要有一行 POST，就说明管道是通的。
  let postSeen = 0;
  const server = http.createServer((req, res) => {
    if (req.method !== 'POST') { res.writeHead(405).end(); return; }
    const auth = req.headers.authorization ?? '';
    // NapCat 的 httpClient 是裸 token（不带 Bearer），别的实现可能带 —— 两种都收。
    // 2026-10-21 23:22：**这台机器上的 NapCat 现在压根不带 Authorization 头**（实测 401 日志里 `Authorization=(空)`），
    //   配置里的 token 字段它没照做。服务只绑 127.0.0.1，所以「本机回环 + 没有头」就放行，
    //   要不然群里永远收不到东西（今晚就是这么静了一晚上）。首次放行记一行，别让它悄无声息。
    const remote = req.socket.remoteAddress ?? '';
    const isLoopback = remote === '127.0.0.1' || remote === '::1' || remote === '::ffff:127.0.0.1';
    const tokenlessLoopback = auth === '' && isLoopback;
    const authOk = TOKEN === '' || auth === `Bearer ${TOKEN}` || auth === TOKEN || tokenlessLoopback;
    if (tokenlessLoopback && !startServer.warnedOnce) {
      startServer.warnedOnce = true;
      log(`[入口] 放行「本机 + 无 token」的 POST（NapCat 没带 Authorization 头；只在 127.0.0.1 上放这一种）`);
    }
    if (!authOk) {
      // 只记指纹，不记明文：头 6 位 + 长度 + 短 hash，足够跟 onebot-token.txt 对得上对不上
      const fp = (s) => s === '' ? '(空)'
        : `${s.slice(0, 6)}… len=${s.length} sha=${shortHash(s)}`;
      log(`[入口] 401 拒了一个 POST（${req.url}）来自 ${remote} —— 收到 Authorization=${fp(auth)}；`
        + `本机期望 ${fp(`Bearer ${TOKEN}`)} 或 ${fp(TOKEN)}`);
      res.writeHead(401).end();
      return;
    }
    let body = '';
    req.on('data', c => { body += c; });
    req.on('end', () => {
      res.writeHead(204).end();
      postSeen++;
      try {
        const ev = JSON.parse(body);
        const kind = ev?.post_type === 'meta_event' ? 'meta'
          : ev?.message_type === 'group' ? `群${ev.group_id}`
            : ev?.message_type === 'private' ? `私聊${ev.user_id}`
              : (ev?.notice_type ? `notice/${ev.notice_type}` : (ev?.post_type || '?'));
        // meta 心跳很吵（NapCat 每 30 秒一条），只在前 3 条和每 200 条时记一下
        if (kind !== 'meta' || postSeen <= 3 || postSeen % 200 === 0) {
          log(`[入口] #${postSeen} POST ${req.url} ${body.length}B → ${kind}`);
        }
        // 2026-10-20 20:40 临时诊断：NapCat 到底推不推非 message 事件（戳一戳走 notice）。
        // 只记 post_type/notice_type/sub_type + 谁戳谁，不记正文。查到就删掉这段。
        if (ev?.post_type && ev.post_type !== 'message' && ev.post_type !== 'message_sent' && ev.post_type !== 'meta_event') {
          log(`[事件] post=${ev.post_type} notice=${ev.notice_type ?? '-'} sub=${ev.sub_type ?? '-'}`
            + ` user=${ev.user_id ?? '-'} target=${ev.target_id ?? '-'} group=${ev.group_id ?? '-'}`);
        }
        if (ev?.message_type === 'group' && (ev?.post_type === 'message' || ev?.post_type === 'message_sent')) {
          const item = pushEvent(ev);
          const gid = String(ev.group_id);
          // 点了她、叫了她的名字、或者这场话本来就没散 —— 值得马上看一眼（不然闲聊里的接话会慢 5 分钟）
          // 2026-10-21 23:52：加了 `item?.named` —— 他 23:48 打的是文字「@大肥鱼」而不是真 @ 段，
          //   以前这种要等下一个 5 分钟整点，他等得着急（"你为什么不回复我群里的@"）。
          if (item?.addressed || item?.named || threadActive(gid)) scheduleQuick();
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
  // ⚠ 2026-10-21：**按行 try** —— 以前整段一个 try，文件头一行带 BOM（﻿）就让 JSON.parse 抛错，
  //   整个窗口一条都读不进去，`--once` 静悄悄什么都不判断（踩过一次，排查了半天）。
  try {
    const lines = fs.readFileSync(RAW_FILE, 'utf8').split('\n').filter(Boolean).slice(-60);
    for (const raw of lines) {
      let x;
      try { x = JSON.parse(raw.replace(/^\uFEFF/, '')); } catch { continue; }
      if (!x || typeof x.ts !== 'number') continue;
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

