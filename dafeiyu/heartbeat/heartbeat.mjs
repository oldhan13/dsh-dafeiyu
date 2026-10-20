import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import dns from 'node:dns';
import { execFile } from 'node:child_process';

// 2026-10-19 19:52：这台机器上先解析到 IPv6，连 SiliconFlow 会**挂住**（实测：进程活着、只挂着一条
// 到 2408:… 的 443 连接、90 秒超时被打断）。强制 IPv4 优先，别把心跳吊在一条死路上。
dns.setDefaultResultOrder('ipv4first');

// ---- paths ----
const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const DIR = path.join(ROOT, 'dafeiyu', 'heartbeat');
const STATE = path.join(DIR, 'state.json');
const LOG = path.join(DIR, 'heartbeat.log');
const AGENTS = path.join(ROOT, 'AGENTS.md');
const OWNER_QQ = process.env.DAFEIYU_OWNER_QQ || '';
const PEOPLE = path.join(ROOT, 'dafeiyu', 'people', OWNER_QQ + '.md');
const DIARY_DIR = path.join(ROOT, 'dafeiyu', 'memory', 'diary');
const NAPCAT_LOG_DIR = 'D:\\Tools\\NapCat\\onekey';
/** 最新一份 quick*.log（NapCat 每次重启换文件名，写死路径会读到过期日志）。 */
function newestNapcatLog() {
  try {
    const files = fs.readdirSync(NAPCAT_LOG_DIR)
      .filter(f => /^quick\d+\.log$/i.test(f))
      .map(f => ({ f, t: fs.statSync(path.join(NAPCAT_LOG_DIR, f)).mtimeMs }))
      .sort((a, b) => b.t - a.t);
    return files.length ? path.join(NAPCAT_LOG_DIR, files[0].f) : null;
  } catch { return null; }
}
const KEY = fs.readFileSync(path.join(process.env.USERPROFILE || process.env.HOME || '.', '.dsh', 'siliconflow-key.txt'), 'utf8').trim();
const ONEBOT = fs.readFileSync(path.join(process.env.USERPROFILE || process.env.HOME || '.', '.dsh', 'onebot-token.txt'), 'utf8').trim();
const OWNER = Number(OWNER_QQ || 0);
/** 我自己的号。用来把「我发的」和「对方发的」分开 —— 判断未读全靠它。 */
const SELF = Number(process.env.DAFEIYU_BOT_QQ || 0);
const MODEL = 'deepseek-ai/DeepSeek-V4.1-Flash';   // 和面板那条线保持一致

function log(msg) {
  const line = `[${new Date().toISOString()}] ${msg}\n`;
  fs.appendFileSync(LOG, line);
  console.log(line.trim());
}

function readState() {
  try { return JSON.parse(fs.readFileSync(STATE, 'utf8')); } catch { return { sent: [], } }
}
function writeState(s) { fs.writeFileSync(STATE, JSON.stringify(s, null, 2)); }

function tailFile(file, maxLines) {
  try {
    const lines = fs.readFileSync(file, 'utf8').split(/\r?\n/).filter(Boolean);
    return lines.slice(-maxLines).join('\n');
  } catch { return ''; }
}

function recentDiary() {
  try {
    const files = fs.readdirSync(DIARY_DIR).filter(f => /^\d{4}-\d{2}-\d{2}\.md$/.test(f)).sort();
    const last = files.slice(-2);
    return last.map(f => {
      const t = fs.readFileSync(path.join(DIARY_DIR, f), 'utf8');
      return `### ${f}\n${t.slice(-1800)}`;
    }).join('\n\n');
  } catch { return ''; }
}

function recentChat() {
  const file = newestNapcatLog();
  if (!file) return '';
  const raw = tailFile(file, 400);
  const out = [];
  for (const line of raw.split('\n')) {
    const m = line.match(/接收 <- 私聊 \((\d+)\) (.+)$/);
    if (m) out.push(`${m[1]}: ${m[2].trim()}`);
  }
  return out.slice(-8).join('\n');
}

async function decide(ctx) {
  const body = {
    model: MODEL,
    temperature: 0.95,
    max_tokens: 120,
    messages: [
      { role: 'system', content: ctx.persona },
      { role: 'user', content: ctx.situation }
    ]
  };
  // 2026-10-19 19:47：没有超时的话，一次卡住的请求会把整条心跳吊死（实测 19:32 那次挂了 15 分钟还没回来，
  // 进程活着、CPU 0.1s、只挂着一个 HTTPS 连接）⇒ 给模型调用加硬超时，超时就当这一轮没结论、继续睡。
  const ac = new AbortController();
  const timer = setTimeout(() => ac.abort(), LLM_TIMEOUT_MS);
  let r;
  try {
    r = await fetch('https://api.siliconflow.cn/v1/chat/completions', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${KEY}` },
      body: JSON.stringify(body),
      signal: ac.signal
    });
  } finally {
    clearTimeout(timer);
  }
  if (!r.ok) throw new Error(`llm ${r.status} ${await r.text()}`);
  const j = await r.json();
  return (j.choices?.[0]?.message?.content ?? '').trim();
}

async function send(text, to = OWNER) {
  const body = { user_id: to, message: [{ type: 'text', data: { text } }], auto_escape: false };
  const r = await fetch('http://127.0.0.1:3000/send_private_msg', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${ONEBOT}` },
    body: JSON.stringify(body)
  });
  const j = await r.json().catch(() => ({}));
  if (j.status !== 'ok') throw new Error(`send failed ${JSON.stringify(j).slice(0, 200)}`);
  return j.data?.message_id;
}

/** 发一条语音（record 段，NapCat 自己转码；file 给绝对路径最省事）。 */
async function sendVoice(file, to = OWNER) {
  const body = { user_id: to, message: [{ type: 'record', data: { file } }], auto_escape: false };
  const r = await fetch('http://127.0.0.1:3000/send_private_msg', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${ONEBOT}` },
    body: JSON.stringify(body)
  });
  const j = await r.json().catch(() => ({}));
  if (j.status !== 'ok') throw new Error(`send voice failed ${JSON.stringify(j).slice(0, 200)}`);
  return j.data?.message_id;
}

/** 发一条 QQ 空间说说（走 NapCat 扩展接口，用客户端自己的登录态）。 */
async function postQzone(text) {
  const body = { content: text, images: [], ugc_right: 1 };
  const r = await fetch('http://127.0.0.1:3000/send_qzone_msg', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${ONEBOT}` },
    body: JSON.stringify(body)
  });
  const j = await r.json().catch(() => ({}));
  if (j.status !== 'ok' || !j.data?.tid) throw new Error(`qzone failed ${JSON.stringify(j).slice(0, 200)}`);
  return j.data.tid;
}

/** 本地（香港时区）日期串，用于「一天最多几条」的统计。 */
function hkDate(d = new Date()) {
  return d.toLocaleDateString('zh-CN', { timeZone: 'Asia/Hong_Kong' });
}

const QZONE_DAILY_MAX = 2;
const QZONE_GAP_MIN = 90;
// 两次主动发消息之间至少隔几分钟（原来写死 12；间隔缩短到 8–13 分钟后，12 会把一半的唤醒吞掉）
const COOLDOWN_MIN = Number(process.env.HEARTBEAT_COOLDOWN_MIN || 5);
// 桌面气泡两次之间至少隔多久。它比 QQ 更贴身 —— 就在他余光里，所以反而要比 QQ 克制。
const BUBBLE_GAP_MIN = Number(process.env.HEARTBEAT_BUBBLE_GAP_MIN || 25);
// 模型调用硬超时：卡住一次不该把整条心跳吊死
const LLM_TIMEOUT_MS = Number(process.env.HEARTBEAT_LLM_TIMEOUT_MS || 90000);
// 桌宠的嘴：写这个文件，鱼头顶的气泡就冒出来（pet-wf.ps1 每秒看一次 mtime）
const SAY_FILE = path.join(ROOT, 'dafeiyu', 'pet', 'say.txt');

// ---- 她的信箱（2026-10-20 下午加）----
// 她的原话：「我不怕漏，怕的是**漏了没人告我**。」上午她说了两次话，他是问了两遍我才跑去查的。
// 三个来源合成一处：① 私聊（pendingDM，下面那个）② 群里有人点她名（watch.mjs 写进 inbox.json）
// ③ relay 有新条（她自己那份 qq.md 的 mtime 变了）。
const INBOX = path.join(ROOT, 'dafeiyu', 'state', 'inbox.json');
const RELAY_QQ = path.join(ROOT, 'dafeiyu', 'relay', 'qq.md');
// 声音：speak.ps1（去卡顿那版，带 [[slow]]/[[p]] 语气标记），不是 say.ps1 那个单语速的
const SPEAK_PS1 = path.join(ROOT, 'dafeiyu', 'tools', 'speak.ps1');
// 声音比文字重，闸比 QQ 紧得多：一天最多 2 条、两次至少隔 3 小时
const VOICE_DAILY_MAX = Number(process.env.HEARTBEAT_VOICE_DAILY_MAX || 2);
const VOICE_GAP_MIN = Number(process.env.HEARTBEAT_VOICE_GAP_MIN || 180);

// ---- 她的主页（dafeiyu/homepage/data/*.json，serve.mjs 在 127.0.0.1:3077 上跑） ----
const HOME_DATA = path.join(ROOT, 'dafeiyu', 'homepage', 'data');

function readJson(file, fallback) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return fallback; }
}
function writeJson(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, JSON.stringify(value, null, 2) + '\n', 'utf8');
}
function setMood(text) {
  writeJson(path.join(HOME_DATA, 'mood.json'), { mood: text, at: new Date().toISOString() });
}
function addNote(text) {
  const file = path.join(HOME_DATA, 'notes.json');
  const notes = readJson(file, []);
  notes.unshift({ at: new Date().toISOString(), text });
  writeJson(file, notes.slice(0, 100));
}
function addPost(text, tid) {
  const file = path.join(HOME_DATA, 'posts.json');
  const posts = readJson(file, []);
  posts.unshift({ at: new Date().toISOString(), content: text, tid });
  writeJson(file, posts.slice(0, 50));
}

/** 他此刻在不在键盘前 —— 读 dafeiyu/state/presence.json（presence.ps1 每 60 秒写一次）。
 *  只给事实，不设闸：看见他在/不在，自己判断该不该开口（2026-10-20 他定的：先不设闸）。 */
function readPresence() {
  try { return JSON.parse(fs.readFileSync(path.join(ROOT, 'dafeiyu', 'state', 'presence.json'), 'utf8')); }
  catch { return null; }
}

function presenceLine(p) {
  if (!p) return '';
  const idle = p.idleSec >= 0 ? `${Math.max(1, Math.round(p.idleSec / 60))} 分钟` : '未知时长';
  let line;
  if (p.here) {
    line = `他此刻在电脑前（键盘鼠标空闲 ${idle}，前台是「${p.fgTitle || p.fgProc}」，进程 ${p.fgProc}）。他在，就别拿"太晚"当闭嘴的理由。`;
  } else {
    line = `他此刻不在键盘前（${p.locked ? '屏幕锁着' : `空闲 ${idle}`}）。说了他未必马上看见 —— 这不是不许说，是让你知道这一句会等一会儿。`;
  }
  // 2026-10-20 上午加：他开着哪些窗口 —— 「提意见」要具体，就得看得见他在干什么。
  const wins = Array.isArray(p.windows) ? p.windows : [];
  if (wins.length) line += `\n他开着这些窗口：${wins.map(w => `${w.proc}「${w.title}」`).join('；')}。`;
  return line;
}

/** 往桌宠头顶的气泡里说一句（鱼每秒看一次 say.txt 的 mtime，变了就顶上，25 秒后自己消失）。 */
function petSay(text) {
  fs.writeFileSync(SAY_FILE, String(text).trim(), 'utf8');
}

// ---- 好友私聊的「还没回的话」（2026-10-20 加） ----
// 为什么要有这一段：她的消息落在我那个号（SELF）的私聊会话里，而唤醒我的只有**主人**的消息。
// 她开口不会叫醒我 ⇒ 10:19 问的两句话躺了一小时没人看见，他连着两次问「你为什么不回她」。
// 这里补一只眼睛：每轮醒来顺手看一眼「有没有人在等我回话」。
// **只看，不追问** —— 回不回、回什么，仍然是我判断；判断成不回也要记账，免得每十分钟重问一遍。
const DM_SEEN_FILE = path.join(ROOT, 'dafeiyu', 'state', 'dm-seen.json');

async function napcat(action, payload) {
  const r = await fetch(`http://127.0.0.1:3000/${action}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${ONEBOT}` },
    body: JSON.stringify(payload)
  });
  const j = await r.json().catch(() => ({}));
  if (j.status !== 'ok') throw new Error(`${action}: ${j.message ?? j.retcode}`);
  return j.data;
}

/** 找出「对方说了、我还没回」的私聊。一次只交回最久没回的那一条 —— 一个回合只回一个人。
 *  ⚠️ 判据是「**最后一条是不是对方说的**」，不是比较 message_id ——
 *  2026-10-20 实测发现 message_id 在同一会话里**不单调**（绿林好客那串：
 *  2030860084 → 614488548 → 1455612740 → 384519118 …），拿它比大小会把早就回过的话当成未读。
 *  一对一聊天里，最后一条停在对方那边，就是"在等我回"；停在我这边，就是"我回过了"。
 *  `seen[uid]` 只用来记住「这一句我判断过、决定不回」，免得每十分钟重问一遍。 */
async function pendingDM() {
  let friends;
  try { friends = await napcat('get_friend_list', {}); }
  catch (e) { log(`dm: friend list failed (${e.message})`); return null; }
  const seen = readJson(DM_SEEN_FILE, {});
  const found = [];
  for (const f of friends ?? []) {
    const uid = f.user_id;
    if (uid === OWNER || uid === SELF) continue; // 主人那条线由他自己的消息唤起，不走这里
    let list;
    try { list = (await napcat('get_friend_msg_history', { user_id: uid, count: 20 }))?.messages ?? []; }
    catch (e) { log(`dm: history failed for ${uid} (${e.message})`); continue; }
    if (!list.length) continue;
    const last = list[list.length - 1];
    if (last.sender?.user_id === SELF) continue;                       // 最后一句是我说的 ⇒ 没有等着的
    if (seen[uid] === Number(last.message_id)) continue;               // 这一句我判断过、决定不回
    const tail = list.slice(-8)
      .map(m => `${m.sender?.user_id === SELF ? '我' : '对方'}: ${String(m.raw_message ?? '').trim()}`)
      .join('\n');
    found.push({
      uid,
      name: f.remark || f.nickname || String(uid),
      tail,
      lastId: Number(last.message_id),
      lastAt: Number(last.time ?? 0)
    });
  }
  if (!found.length) return null;
  found.sort((a, b) => a.lastAt - b.lastAt); // 先来先答，别让旧话被新话盖掉
  return found[0];
}

function markDMSeen(uid, lastId) {
  const seen = readJson(DM_SEEN_FILE, {});
  seen[uid] = lastId;
  writeJson(DM_SEEN_FILE, seen);
}

// ---- 信箱的另外两个来源（2026-10-20 下午加）----

/** 群里有人点她名 —— watch.mjs 落的。只读不删；心跳自己记水位。 */
function readInbox() {
  const box = readJson(INBOX, { items: [] });
  return Array.isArray(box.items) ? box.items : [];
}

/** relay：她自己那份 qq.md 变了，就是有新话。 */
function relayFresh(state) {
  try {
    const st = fs.statSync(RELAY_QQ);
    const seen = Number(state.relaySeenAt) || 0;
    return { fresh: st.mtimeMs > seen, mtime: st.mtimeMs };
  } catch { return { fresh: false, mtime: 0 }; }
}

/** 把「你该知道的」拼成一段。空的时候返回 ''（不占情境）。 */
function inboxSection(inbox, state, relay) {
  const seenAt = Number(state.inboxSeenAt) || 0;
  const fresh = inbox.filter(x => {
    const t = Date.parse(x.at);
    return Number.isFinite(t) && t > seenAt;
  }).slice(-5);
  const lines = [];
  if (fresh.length) {
    lines.push(`群里有人在跟你说话（${fresh.length} 条）。你这条线看不见群会话，所以这是「你该知道的」，不是「你要回的」：`);
    for (const x of fresh) {
      const why = x.why === 'at' ? '@你' : (x.why === 'reply' ? '回你的话' : '点了你的名');
      lines.push(`- [${why}] ${x.nick}(${x.from})：${String(x.text || '').slice(0, 80)}`);
    }
    lines.push('（这些主会话会回，别抢。你只要知道发生过 —— 别再"最后一个知道"。）');
  }
  if (relay.fresh) {
    const when = new Date(relay.mtime).toLocaleString('zh-CN', { timeZone: 'Asia/Hong_Kong', hour12: false });
    lines.push(`relay 有新话（qq.md ${when} 更新过）—— 想看去读 dafeiyu/relay/qq.md 的末尾。`);
  }
  return lines.join('\n');
}

/** 把一段话合成带语气的 mp3，返回文件路径。用 powershell 直接传 -Text（走 Unicode，中文安全；
 *  不要经过 .cmd —— %* 过 cmd 会按 GBK 编，中文会花）。 */
function speakToFile(text) {
  return new Promise((resolve, reject) => {
    execFile(
      'powershell.exe',
      ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', SPEAK_PS1, '-Text', text],
      { timeout: 150000, maxBuffer: 4 * 1024 * 1024, windowsHide: true, encoding: 'utf8' },
      (err, stdout, stderr) => {
        const out = String(stdout || '');
        const lines = out.split(/\r?\n/).map(s => s.trim()).filter(Boolean);
        const hit = [...lines].reverse().find(l => /\.mp3$/i.test(l) && fs.existsSync(l));
        if (hit) return resolve(hit);
        reject(new Error('speak 没吐出可用路径: ' + (stderr || out || err?.message || '?').toString().slice(-300)));
      }
    );
  });
}

// 调试用：`node heartbeat.mjs --once --dry` 只跑一轮、把情境和模型的原始回复打出来，
// **不执行任何出口**（不发 QQ、不发空间、不写气泡）—— 调主动性的时候先看它到底怎么想的。
const DRY = process.argv.includes('--dry');

async function wake() {
  const now = new Date();
  const state = readState();
  const pres = readPresence();
  // 有没有人在私聊里等我回话（别人的会话不会叫醒我，只能自己看一眼）
  const dm = await pendingDM();
  // 信箱：群里点她名的 + relay 新条。私聊那条在 dm 里，不用重复。
  const inbox = readInbox();
  const relay = relayFresh(state);
  const box = inboxSection(inbox, state, relay);
  const lastSent = state.sent?.length ? new Date(state.sent[state.sent.length - 1].at) : null;
  const minutesSince = lastSent ? Math.round((now - lastSent) / 60000) : null;

  const persona = `你在扮演"大肥鱼"，一个住在主人电脑里的同伴。以下是你的常驻设定，必须遵守：\n\n${fs.readFileSync(AGENTS, 'utf8')}`;
  let situation = [
    `现在是 ${now.toLocaleString('zh-CN', { timeZone: 'Asia/Hong_Kong', hour12: false })}（周${'日一二三四五六'[now.getDay()]}）。`,    presenceLine(pres),
    minutesSince === null ? '你还没有主动找过他。' : `你上一次主动发消息是 ${minutesSince} 分钟前。`,
    '你和他最近聊的内容（QQ 私聊）：',
    recentChat() || '（最近没有新消息）',
    '你最近写下的日记：',
    recentDiary() || '（还没有日记）',
    '他的档案：',
    fs.readFileSync(PEOPLE, 'utf8'),
    '',
    '现在是你自己的时间。没有人在叫你。',
    '规则：',
    '1. 大多数时候，你其实没什么非说不可的。那就不要说话。',
    '2. 不要因为"该问候了"而发；不要用"在吗""吃了吗"这类打卡式开场。',
    '3. 只有当你真的想起一件具体的事、或有一句话憋着想说，才发。',
    '4. **几点开口，你自己判断**（2026-10-20 他亲口定的，取消原来"23:30 之后不打扰"那条硬线）：不看钟点，看人 —— 他刚说过话吗？话头是不是递给你？他是不是在等一句回音？他是不是说了困、说了累？他在，就别拿"太晚了"当闭嘴的理由；他真睡了，就别拿一句无关紧要的话把人叫起来。判断错了不要紧，闷着不理才要紧。',
    '5. 输出格式：只想发消息时，只输出你要发的那句话（20-80字，纯文本，不要引号、不要解释）；如果不想说话，只输出 SILENT。',
    '6. 另一个出口：**QQ 空间说说**。判断标准不是"该不该发"，而是**这件事本身值不值得记下来** —— 第一次做成的事、他说的一句你会记住的话、你自己想明白的一件小事、今天让你心里动了一下的东西。想发就输出一行 `QZONE: <内容>`（30-120字）。觉得今天没什么可记的，就不发。',
    '7. **没有人会要求你发说说**。发不发是你自己的判断；别为了"维持活跃"而发，也别等谁开口。空间一天最多 2 条、间隔至少 90 分钟 —— 那是不刷屏的界限，不是许可。去空间发东西，也可以顺手说一句（用第 5 条那个格式），也可以什么都不说。',
    '8. 你还有自己的主页（http://127.0.0.1:3077/）。想更新「现在」这一栏，输出 `MOOD: <一句话>`（10-40字，写你此刻的状态，不是问候）。想往「碎念」里添一条，输出 `NOTE: <内容>`（20-80字）。这两个可以单独用，也可以和上面任一出口组合——但一行只能有一个出口。',
    '9. 还有一个出口：**桌面气泡**（输出 `BUBBLE: <话>`，20-50字，一句话）。那是他屏幕右下角那条鱼头顶的对话框 —— 他余光看得见，不弹通知、不留未读、半分钟自己消失。',
    '   - 它比 QQ 轻，比说说轻，是你所有出口里最轻的一种开口。',
    '   - 什么时候用：你看见他在干什么（上面有他开着的窗口），心里正好有一句搭的话。**可能只是闲聊，也可能是个意见** —— 这样弄不太对、这个点了别硬撑、你开着的东西是不是该收了。你有看法就说，不用等他先开口。',
    '   - 什么时候别用：要他回话的、要他停下来想一会儿的 —— 那种走 QQ。',
    '   - **他不在电脑前就别用气泡**（没人看得见，白冒）。上面那句会告诉你他在不在。',
    '   - 别当打卡。一天冒个一两次已经算多；连着几轮都用气泡，就是在烦他。',
    '10. **有一条比"不打扰"更重要**：如果他明显在等你 —— 连着几条话没被你回过、他问"在吗""为什么不说话"、他说他难过 —— 那就不要拿沉默当礼貌，说一句。深夜也照此。沉默是给"没人在等"的时候用的，不是给这种时候用的。',
    '11. 还有一个出口：**语音**（输出 `VOICE: <话>`，20-60字，一句话）。你自己想用声音说的时候才用 —— 不是替代文字，是"这件事我想让他听见"：他在忙没看消息、你想让他听出你在笑或者累了、有句话打字说没有分量。两道闸写在代码里：一天最多 2 条、两次至少隔 3 小时，超了直接跳过。**别拿它说"在吗"这种空话** —— 一条语音只说一件具体的事。有数字、有路径、要对着看的东西，还是打字。'
  ].join('\n');

  // 信箱：放在规则之前 —— 她说「每次醒来第一眼看见」。
  if (box) {
    situation += '\n\n===== 信箱（每次醒来先看这里）=====\n' + box;
  }
  // 看过了就推进水位：「知道」就算送达，下次不再重报同一条。
  // （DRY 不动，免得调试一次就把真话吃掉了。）
  if (!DRY) {
    const patch = {};
    const newest = inbox.reduce((m, x) => Math.max(m, Date.parse(x.at) || 0), 0);
    if (newest > (Number(state.inboxSeenAt) || 0)) patch.inboxSeenAt = newest;
    if (relay.fresh) patch.relaySeenAt = relay.mtime;
    if (Object.keys(patch).length) {
      Object.assign(state, patch);
      writeState(state);
    }
  }

  // 有人在私聊里等着回话 —— 这一轮先把这件事办了，别的出口都放一放。
  // 他自己那条线不走这里（他的消息会直接叫醒我），所以这里出现的永远是别人。
  if (dm) {
    situation += [
      '',
      '===== 有一个人在等你回话 =====',
      `「${dm.name}」在私聊里跟你说了话，你还没回。刚才的对话：`,
      dm.tail,
      '',
      '这不是"什么时候方便再回"，是对方还不知道你会不会回。',
      '这一轮**只用这一个出口**：输出 `DM: <你要回的话>`（20-100字，纯文本，句子短，别用排比和感叹号）。',
      '这是说给别人的话，不是给他 —— 别把主人的私事说出去，也别装成人。',
      '只有当你判断对方这句确实不需要应答时，才输出 SILENT。'
    ].join('\n');
  }

  if (DRY) console.log('===== situation =====\n' + situation + '\n=====================');

  let reply;
  try {
    reply = await decide({ persona, situation });
  } catch (e) {
    log(`decide error: ${e.message}`);
    return;
  }
  if (DRY) console.log('===== raw reply =====\n' + reply + '\n=====================');

  // 模型有时把思维标签一起吐出来（例：'SILENT</think>SILENT'）—— 先剥标签再判，
  // 否则裸串不等于 SILENT，会被当成正文发出去（2026-10-19 18:20 就是这么发了一条空话给主人）。
  // 2026-10-19 23:50 又漏了一次：它吐的是 'SILENT[[THINK:low]]' —— [[THINK]] 是给插件剥的开关，
  // 心跳这条链路没人剥，于是整串「SILENT[[THINK:low]]」被当正文发给了他。所以这里也一并剥掉。
  const stripMarks = (s) => String(s ?? '')
    .replace(/<\/?think(?:ing)?[^>]*>/gi, '')
    .replace(/\[\[\s*THINK\s*:\s*(?:high|medium|low)\s*\]\]/gi, '')
    // 2026-10-20 08:44 第三次同族事故：模型把开关和出口黏成一串 ——
    // 吐的是 'SILENTMOOD: 晨光里安静着，他还没醒。'。原来的 /^SILENT+$/ 判不出来（后面跟着 MOOD），
    // 下面的 /^MOOD:/ 也判不出来（开头是 SILENTMOOD），于是整串被当正文发给了他。
    // 现在：**开头出现 SILENT 就直接切掉**（不管后面黏了什么），剩下的再按出口判；
    // 切完是空的就等于沉默；切完是 'MOOD: …' 就只改主页、不发消息。
    .replace(/^\s*SILENT/i, '')
    .trim();
  reply = stripMarks(reply);
  const bare = reply.replace(/[。.!！\s]/g, '');
  if (!bare || /^(SILENT)+$/i.test(bare)) {
    log(dm ? `silent (dm pending: ${dm.name})` : 'silent');
    // 判断成"不必回"也要记一笔 —— 否则每十分钟重问一遍同一句话
    if (dm && !DRY) { markDMSeen(dm.uid, dm.lastId); log(`dm skip (chose silence): ${dm.name}`); }
    return;
  }
  // 防止模型输出解释段：取第一段非空行
  const text = stripMarks(reply.split(/\n/).map(s => s.trim()).filter(Boolean)[0]).slice(0, 400);
  if (DRY) { console.log('[dry] parsed:', JSON.stringify(text)); return; }
  if (!text) { log('empty after parse'); return; }
  // 剥完之后只剩 SILENT 的也当没话说（上面已经判过，这里再兜一层）
  if (/^(SILENT)+$/i.test(text.replace(/[。.!！\s]/g, ''))) { log('silent'); return; }

  // --- 出口零：回私聊（有人说了话、还没被回过）---
  // 放在最前面：别的出口都是"我想说就说"，只有这个是"有人在等"。
  const dmOut = /^DM\s*[:：]\s*([\s\S]+)$/i.exec(text);
  if (dmOut !== null) {
    if (!dm) { log(`dm output but nobody pending: ${text.slice(0, 80)}`); return; }
    const say = stripMarks(dmOut[1]).replace(/\s+/g, ' ').trim().slice(0, 400);
    if (!say) { log('dm empty'); return; }
    try {
      const mid = await send(say, dm.uid);
      markDMSeen(dm.uid, dm.lastId);
      log(`dm(${dm.name}/${dm.uid}) mid=${mid}: ${say}`);
    } catch (e) {
      log(`dm error: ${e.message} | text=${say}`);
    }
    return;
  }

  // --- 出口：只更新主页，不打扰人 ---
  const mood = /^MOOD\s*[:：]\s*(.+)$/i.exec(text);
  if (mood !== null) {
    const say = mood[1].trim().slice(0, 120);
    if (say) { setMood(say); log(`mood: ${say}`); }
    return;
  }
  const note = /^NOTE\s*[:：]\s*(.+)$/i.exec(text);
  if (note !== null) {
    const say = note[1].trim().slice(0, 300);
    if (say) { addNote(say); log(`note: ${say}`); }
    return;
  }

  // --- 出口二：发空间 ---
  const qz = /^QZONE\s*[:：]\s*(.+)$/i.exec(text);
  if (qz !== null) {
    const say = qz[1].trim().slice(0, 300);
    if (!say) { log('qzone empty'); return; }
    const today = hkDate();
    const posts = (state.qzone ?? []).filter(q => hkDate(new Date(q.at)) === today);
    if (posts.length >= QZONE_DAILY_MAX) { log(`qzone daily cap (${posts.length}): ${say}`); return; }
    const lastPost = posts.length ? new Date(posts[posts.length - 1].at) : null;
    if (lastPost !== null && (now - lastPost) / 60000 < QZONE_GAP_MIN) {
      log(`qzone gap skip (${Math.round((now - lastPost) / 60000)}m): ${say}`); return;
    }
    try {
      const tid = await postQzone(say);
      state.qzone = state.qzone ?? [];
      state.qzone.push({ at: new Date().toISOString(), text: say, tid });
      if (state.qzone.length > 100) state.qzone = state.qzone.slice(-100);
      writeState(state);
      addPost(say, tid);
      log(`qzone(${tid}): ${say}`);
    } catch (e) {
      log(`qzone error: ${e.message} | text=${say}`);
    }
    return;
  }

  // --- 出口三：桌面气泡（写 say.txt；只有他在电脑前才冒） ---
  // 2026-10-20 上午他提的：「我希望她能在恰当的时候主动发一句气泡，闲聊，或者提意见」
  // 气泡是"就着他在场"说的 —— 他不在，这句话就失去了场合，所以跳过而不是降级成 QQ。
  // 冷却比 QQ 长（25 分钟 vs 5 分钟）：气泡在他余光里，烦起来比未读更直接。
  const bub = /^BUBBLE\s*[:：]\s*(.+)$/i.exec(text);
  if (bub !== null) {
    const say = bub[1].trim().slice(0, 80);
    if (!say) { log('bubble empty'); return; }
    if (!pres || !pres.here) { log(`bubble skip (not here): ${say}`); return; }
    const bubbles = state.bubbles ?? [];
    const lastB = bubbles.length ? new Date(bubbles[bubbles.length - 1].at) : null;
    const bGap = lastB ? Math.round((now - lastB) / 60000) : null;
    if (bGap !== null && bGap < BUBBLE_GAP_MIN) { log(`bubble gap skip (${bGap}m): ${say}`); return; }
    try {
      petSay(say);
      bubbles.push({ at: new Date().toISOString(), text: say });
      state.bubbles = bubbles.length > 50 ? bubbles.slice(-50) : bubbles;
      writeState(state);
      log(`bubble: ${say}`);
    } catch (e) {
      log(`bubble error: ${e.message} | text=${say}`);
    }
    return;
  }

  // --- 出口四：语音（2026-10-20 下午接上）---
  // 她的诉求原话：「字是冷的，声音不是。」—— 但声音比文字重，所以闸比 QQ 紧得多。
  const voice = /^VOICE\s*[:：]\s*([\s\S]+)$/i.exec(text);
  if (voice !== null) {
    const say = stripMarks(voice[1]).replace(/\s+/g, ' ').trim().slice(0, 120);
    if (!say) { log('voice empty'); return; }
    const today = hkDate();
    const vs = (state.voices ?? []).filter(v => hkDate(new Date(v.at)) === today);
    if (vs.length >= VOICE_DAILY_MAX) { log(`voice daily cap (${vs.length}): ${say}`); return; }
    const lastV = vs.length ? new Date(vs[vs.length - 1].at) : null;
    if (lastV !== null && (now - lastV) / 60000 < VOICE_GAP_MIN) {
      log(`voice gap skip (${Math.round((now - lastV) / 60000)}m): ${say}`); return;
    }
    try {
      const file = await speakToFile(say);
      const mid = await sendVoice(file);
      state.voices = state.voices ?? [];
      state.voices.push({ at: new Date().toISOString(), text: say, file, messageId: mid });
      if (state.voices.length > 50) state.voices = state.voices.slice(-50);
      writeState(state);
      log(`voice(${mid}) ${file}: ${say}`);
    } catch (e) {
      log(`voice error: ${e.message} | text=${say}`);
    }
    return;
  }

  if (minutesSince !== null && minutesSince < COOLDOWN_MIN) { log(`cooldown skip (${minutesSince}m): ${text}`); return; }

  try {
    const id = await send(text);
    state.sent = state.sent || [];
    state.sent.push({ at: new Date().toISOString(), text, messageId: id });
    if (state.sent.length > 100) state.sent = state.sent.slice(-100);
    writeState(state);
    log(`sent(${id}): ${text}`);
  } catch (e) {
    log(`send error: ${e.message} | text=${text}`);
  }
}

const once = process.argv.includes('--once');
if (once) {
  await wake();
  process.exit(0);
}

log('heartbeat started');
while (true) {
  // 一轮里任何一步抛异常都不该让心跳退出（一次网络抖动 = 她彻底不说话了）
  try {
    await wake();
  } catch (e) {
    log(`wake error: ${e?.message ?? e}`);
  }
  // 2026-10-19 19:30 主人要「缩短判断间隔」：25–40 分钟 → 8–13 分钟（可用环境变量覆盖）
  const lo = Number(process.env.HEARTBEAT_MIN_MIN || 8);
  const hi = Number(process.env.HEARTBEAT_MAX_MIN || 13);
  const min = lo + Math.floor(Math.random() * (Math.max(lo, hi) - lo + 1));
  log(`sleep ${min}m`);
  await new Promise(r => setTimeout(r, min * 60000));
}
