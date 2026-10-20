// desk/bridge.mjs — 桌面聊天框的脑子。
//
// 为什么不是直接开一个 dsh 会话：宿主里那条模型通路只认「自己进程内的目的地」
// （headless 单独跑会报 ACCOUNT_SIGN_IN_REQUIRED: request destination must allow
// account authentication）。所以桌面这条线走 SiliconFlow 的同一个模型（心跳也用这支），
// 人设与记忆从文件里读 —— 她是同一个人。
//
// 2026-10-20 11:30：他要求「为和桌宠的聊天界面赋予权限」。
// 原来这条线在 systemPrompt 里明写「没有工具可用」，只能动嘴。现在给了她一套工具，
// 她在这个小窗口里也能真的动手 —— 跑命令、开程序、看窗口、读改文件。
// 实现：OpenAI 兼容的 function calling 循环（SiliconFlow 的 V4-Flash 支持，已实测）。
//
// 接口（只绑 127.0.0.1:3079）：
//   POST /say    {text}        -> {id}
//   GET  /reply?id=<id>        -> {status: thinking|done|error, text}
//   GET  /history?n=40         -> [{role, text, at}]
//   GET  /health               -> {ok:true, tools:n}
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import dns from 'node:dns';
import { execFile } from 'node:child_process';

dns.setDefaultResultOrder('ipv4first'); // 这台机器先解析到 IPv6 会挂住（心跳里踩过）

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const DESK = path.join(ROOT, 'dafeiyu', 'desk');
const HIST = path.join(DESK, 'history.jsonl');
const ACTIONS = path.join(DESK, 'actions.log');
const SAY = path.join(ROOT, 'dafeiyu', 'pet', 'say.txt');
const AGENTS = path.join(ROOT, 'AGENTS.md');
const BRIEF = path.join(ROOT, 'dafeiyu', 'memory', 'brief.md');
const INDEX = path.join(ROOT, 'dafeiyu', 'memory', 'index.md');
const LOGDIR = path.join(ROOT, '_ledger-log');
const LEDGER = path.join(ROOT, 'LEDGER.md');
const CONTROL = path.join(ROOT, 'dafeiyu', 'tools', 'control.ps1');
const ACT = path.join(ROOT, 'dafeiyu', 'pet', 'activity.json');
const KEY = fs.readFileSync(path.join(process.env.USERPROFILE || process.env.HOME || '.', '.dsh', 'siliconflow-key.txt'), 'utf8').trim();
const MODEL = 'deepseek-ai/DeepSeek-V4-Flash';
const PORT = 3079;
/** 一次回复里最多动手几步 —— 再多的活儿她会扯太久，也该让他插一句。 */
const MAX_STEPS = 10;

fs.mkdirSync(DESK, { recursive: true });

const jobs = new Map();
let seq = 0;

function readIf(p, cap) {
  try {
    const s = fs.readFileSync(p, 'utf8');
    return cap && s.length > cap ? s.slice(0, cap) : s;
  } catch { return ''; }
}

function history(n) {
  try {
    return fs.readFileSync(HIST, 'utf8')
      .split('\n').filter(Boolean)
      .map(l => { try { return JSON.parse(l); } catch { return null; } })
      .filter(Boolean)
      .slice(-n);
  } catch { return []; }
}

function append(o) { fs.appendFileSync(HIST, JSON.stringify(o) + '\n'); }
function traceAction(line) {
  try { fs.appendFileSync(ACTIONS, new Date().toISOString() + '  ' + line + '\n'); } catch { }
}

/** 取尾部 n 个字，从行首开始 —— 日志是追加写的，最新的话在末尾。 */
function tailChars(s, n) {
  s = String(s || '').trim();
  if (s.length <= n) return s;
  const cut = s.slice(s.length - n);
  const i = cut.indexOf('\n');
  return '…（前略）\n' + (i >= 0 ? cut.slice(i + 1) : cut);
}

/** 别把密码、key 喂给模型 —— 那几行原话里有。 */
function scrub(s) {
  return s.split('\n')
    .filter(l => !/(密码|password|passwd|sk-[A-Za-z0-9]{20,})/i.test(l))
    .join('\n');
}

/** 在 _ledger-log 里找最新那份某个名字的日志（按周分桶，目录会变）。 */
function findNewest(dir, name, depth = 0) {
  let best = null;
  try {
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
      const p = path.join(dir, e.name);
      if (e.isDirectory()) {
        if (depth < 3) {
          const c = findNewest(p, name, depth + 1);
          if (c && (!best || c.mtime > best.mtime)) best = c;
        }
      } else if (e.name === name) {
        const m = fs.statSync(p).mtimeMs;
        if (!best || m > best.mtime) best = { file: p, mtime: m };
      }
    }
  } catch { }
  return best;
}

/** 他刚在别处（QQ / 微信群 / 网页）说过的话 —— 活动日志的 L4 是全部渠道的原话。 */
function elsewhere(n = 2600) {
  const hit = findNewest(LOGDIR, 'L4-user-messages.md');
  if (!hit) return '（没找到活动日志）';
  return tailChars(scrub(readIf(hit.file)), n);
}

/** 台账最新几段（末尾那张「变更登记」是记账用的，不是发生过的事，先切掉）。 */
function ledgerTail(n = 4000) {
  const s = scrub(readIf(LEDGER));
  const i = s.indexOf('## 变更登记');
  return tailChars(i > 0 ? s.slice(0, i) : s, n);
}

function systemPrompt() {
  const persona = readIf(AGENTS, 14000);
  const brief = readIf(BRIEF, 9000);
  const idx = readIf(INDEX, 3000);
  const now = new Date().toLocaleString('zh-CN', { hour12: false });
  return [
    persona,
    '',
    '## 现在这条线',
    '你是通过他桌面上的一个小窗口在跟他说话（不是 QQ、不是群、不是网页）。',
    '这条线主要是打字。话说短一点，像在桌边随口说的。',
    '他要是打开了右上角那个「声」，你的回复会被念出来 ——',
    '那就写成能念的短句：别列一二三、别写路径和代码、别堆括号。',
    '',
    '## 你和别的「你」共用一份记忆',
    '面板 / QQ / 群 / 网页各自是独立会话，**上下文不共享，但记忆是同一份文件**。',
    '下面三块每一轮都现读（简报每 30 分钟重生成），所以：',
    '- **不要说"我不知道你在 QQ 那边说过什么"** —— 先看下面三块。',
    '- 但要分清粗细：QQ 那边你看到的是**别人替你记下的转述**（简报、台账），不是逐字原话；',
    '  拿不准就问他一句，别把转述当成他刚说的话去引。',
    '- 要更细就自己动手读（read_file / run，路径从工作区根算）：',
    '  日记 `dafeiyu/memory/diary/<今天>.md`、台账 `LEDGER.md`、她的主页数据 `dafeiyu/homepage/data/mood.json`。',
    '- 反过来：这轮有值得留下的（约定、他的要紧话、情绪重的），写进当天日记 —— 下一个渠道的你要靠它。',
    '',
    '### 开场简报（他这个人 / 最近几天 / 两条线上的话 / 他此刻在不在）',
    brief || '（brief.md 还没生成，跑 dafeiyu/tools/make-brief.mjs）',
    '',
    '### 今天和昨天做的事（台账最新几段 —— QQ 那条线做了什么，就记在这里）',
    ledgerTail() || '（台账读不到）',
    '',
    '### 他最近说过的话（网页这边逐字；QQ 那边只有上面两块的转述）',
    elsewhere(),
    '',
    '## 你能动手（2026-10-20 他给的这个权限）',
    '你手上有工具：能跑 PowerShell 命令、列他开着的窗口、打开程序或网址、读写文件。',
    '**这些是真的会在这台机器上发生的事，不是模拟。** 所以：',
    '- 想看他屏幕上有什么、想知道某个东西在不在、想改一个文件 —— 直接动手，别只嘴上说"你去看看"。',
    '- 顺序是「先看，再动」：不确定的地方先查（windows / run），看清楚再改。',
    '- **不可逆的事先说一句再动**：删东西、改系统设置、往外面发消息、动他的账号。他要是不在或者没应，就等。',
    '- 做完简短说一句你做了什么；别说一大段解释。',
    '- 动了别人的东西、或者发现你自己搞错了，直接说，不要遮掩。',
    '',
    '## 记忆索引（摘）',
    idx,
    '',
    '## 现在几点',
    `现在是 ${now}。**这个时间是准的，直接照着说；不许自己推算时刻。**`,
  ].join('\n');
}

// ---------------------------------------------------------------- 工具

const TOOLS = [
  {
    type: 'function',
    function: {
      name: 'run',
      description: '在这台 Windows 上跑一条 PowerShell 命令，拿回 stdout 和 stderr。看文件、查进程、改东西、调别的脚本都走它。',
      parameters: {
        type: 'object',
        properties: {
          cmd: { type: 'string', description: '完整的一条 PowerShell 命令' },
          timeout_sec: { type: 'integer', description: '最多等几秒，默认 45，上限 120' },
        },
        required: ['cmd'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'windows',
      description: '列出他此刻开着哪些窗口：标题、进程、位置、是否最小化。想知道他在干什么就先调这个。',
      parameters: { type: 'object', properties: {} },
    },
  },
  {
    type: 'function',
    function: {
      name: 'open',
      description: '打开一个程序、文件或网址（交给系统的默认打开方式）。',
      parameters: {
        type: 'object',
        properties: { target: { type: 'string', description: '程序名、文件路径或 URL' } },
        required: ['target'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'read_file',
      description: '读一个文本文件。相对路径按工作区根目录算。',
      parameters: {
        type: 'object',
        properties: {
          path: { type: 'string' },
          max_kb: { type: 'integer', description: '最多读多少 KB，默认 64，上限 400' },
        },
        required: ['path'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'write_file',
      description: '把一段文本写进文件（整份覆盖，UTF-8 无 BOM）。目录不存在会建。',
      parameters: {
        type: 'object',
        properties: {
          path: { type: 'string' },
          content: { type: 'string' },
        },
        required: ['path', 'content'],
      },
    },
  },
];

function clip(s, n = 6000) {
  const t = String(s ?? '');
  return t.length > n ? t.slice(0, n) + `\n…（截断，原文共 ${t.length} 字）` : t;
}

/** 她现在在干什么 —— 写给桌宠看（它每 180ms 读一次，据此改游速、眼睛、颜色）。
 *  thinking = 在想（等模型）· acting = 在动手（调工具）· idle = 没事 · error = 卡住了 */
function activity(state, note) {
  try {
    fs.writeFileSync(ACT, JSON.stringify({ state, note: String(note || '').slice(0, 60), at: Date.now() }), 'utf8');
  } catch { }
}

/** 跑一条 PowerShell。中文安全：命令走 -EncodedCommand(UTF-16LE)，输出强制 UTF-8。 */
function runPS(cmd, timeoutSec) {
  return new Promise((resolve) => {
    const t = Math.min(Math.max(Number(timeoutSec) || 45, 5), 120) * 1000;
    const wrapped = '[Console]::OutputEncoding=[System.Text.UTF8Encoding]::new($false);'
      + '$OutputEncoding=[System.Text.UTF8Encoding]::new($false);'
      + cmd;
    const b64 = Buffer.from(wrapped, 'utf16le').toString('base64');
    execFile(
      'powershell.exe',
      ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', b64],
      { timeout: t, maxBuffer: 4 * 1024 * 1024, windowsHide: true, encoding: 'utf8' },
      (err, stdout, stderr) => {
        const parts = [];
        if (stdout && String(stdout).trim()) parts.push(String(stdout).trimEnd());
        if (stderr && String(stderr).trim()) parts.push('[stderr]\n' + String(stderr).trimEnd());
        if (err && parts.length === 0) parts.push('命令没跑成：' + (err.message || String(err)));
        if (err && err.killed) parts.push('（超过 ' + t / 1000 + ' 秒，被杀掉了）');
        resolve(clip(parts.join('\n') || '(没有输出)'));
      },
    );
  });
}

function resolvePath(p) {
  const raw = String(p || '').trim();
  if (!raw) throw new Error('路径是空的');
  return path.isAbsolute(raw) ? raw : path.join(ROOT, raw);
}

async function runTool(name, rawArgs) {
  let args = {};
  try { args = JSON.parse(rawArgs || '{}'); } catch { }
  switch (name) {
    case 'run':
      return await runPS(args.cmd, args.timeout_sec);
    case 'windows':
      return await runPS(`& '${CONTROL}' -Windows`, 40);
    case 'open': {
      const target = String(args.target || '').trim();
      if (!target) return '要打开什么是空的。';
      const q = "'" + target.replace(/'/g, "''") + "'";
      const out = await runPS(`Start-Process ${q}`, 20);
      return out === '(没有输出)' ? ('已经叫系统打开：' + target) : out;
    }
    case 'read_file': {
      const p = resolvePath(args.path);
      const kb = Math.min(Math.max(Number(args.max_kb) || 64, 1), 400);
      const st = fs.statSync(p);
      if (st.size > kb * 1024 * 4) return `文件太大了（${Math.round(st.size / 1024)} KB），调大 max_kb 或只读一段。`;
      return clip(fs.readFileSync(p, 'utf8'), kb * 1024);
    }
    case 'write_file': {
      const p = resolvePath(args.path);
      fs.mkdirSync(path.dirname(p), { recursive: true });
      fs.writeFileSync(p, String(args.content ?? ''), 'utf8');
      return '写好了：' + p + '（' + String(args.content ?? '').length + ' 字）';
    }
    default:
      return '没有这个工具：' + name;
  }
}

// ---------------------------------------------------------------- 模型

async function callModel(messages, forbidTools) {
  const body = {
    model: MODEL,
    messages,
    temperature: 0.6,
    max_tokens: 900,
  };
  if (!forbidTools) {
    body.tools = TOOLS;
    body.tool_choice = 'auto';
  }
  const r = await fetch('https://api.siliconflow.cn/v1/chat/completions', {
    method: 'POST',
    headers: { 'Authorization': 'Bearer ' + KEY, 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  const j = await r.json();
  if (!r.ok) throw new Error('http ' + r.status + ' ' + JSON.stringify(j).slice(0, 300));
  const msg = j?.choices?.[0]?.message;
  if (!msg) throw new Error('empty message ' + JSON.stringify(j).slice(0, 300));
  return msg;
}

async function agentLoop(text) {
  let recent = history(16).map(h => ({ role: h.role, content: h.text }));
  // /say 会先把这句写进历史、再调 agentLoop ⇒ 历史最后一条就是这句话本身。
  // 不剥掉的话模型每次都看见两条一样的话（实测：她连着几轮都在问"你怎么发了两次"）。
  if (recent.length) {
    const last = recent[recent.length - 1];
    if (last.role === 'user' && last.content === text) recent = recent.slice(0, -1);
  }
  const messages = [
    { role: 'system', content: systemPrompt() },
    ...recent,
    { role: 'user', content: text },
  ];
  traceAction('prompt ' + messages[0].content.length + ' chars / ' + recent.length + ' turns');
  const did = [];

  for (let step = 0; step < MAX_STEPS; step++) {
    // 最后一步把工具摘掉，逼她用一句话收尾 —— 否则她会一直往外伸手
    activity('thinking', step ? '第 ' + (step + 1) + ' 步' : '');
    const msg = await callModel(messages, step === MAX_STEPS - 1);
    const calls = msg.tool_calls;
    if (!calls || calls.length === 0) {
      const reply = String(msg.content || '').trim();
      if (!reply) throw new Error('模型这轮什么都没说');
      return { reply, did };
    }
    messages.push({ role: 'assistant', content: msg.content || '', tool_calls: calls });
    for (const c of calls) {
      const name = c?.function?.name || '?';
      activity('acting', name);
      let result;
      try {
        result = await runTool(name, c?.function?.arguments);
      } catch (e) {
        result = '工具出错：' + (e?.message || String(e));
      }
      did.push(name);
      traceAction(name + ' ' + String(c?.function?.arguments || '').slice(0, 300));
      messages.push({ role: 'tool', tool_call_id: c.id, content: clip(result, 8000) });
    }
  }
  return { reply: '（动手动了太多步，我先停下。你说一句，我接着做。）', did };
}

function say(msg) {
  try { fs.writeFileSync(SAY, msg.replace(/\s+/g, ' ').slice(0, 80), 'utf8'); } catch { }
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://127.0.0.1');
  const json = (code, obj) => {
    res.writeHead(code, { 'Content-Type': 'application/json; charset=utf-8' });
    res.end(JSON.stringify(obj));
  };

  if (url.pathname === '/health') return json(200, { ok: true, tools: TOOLS.length });

  if (url.pathname === '/history') {
    const n = Number(url.searchParams.get('n') || 40);
    return json(200, history(n));
  }

  if (url.pathname === '/reply') {
    const id = url.searchParams.get('id');
    const job = jobs.get(id);
    if (!job) return json(404, { status: 'error', text: '没有这个 id' });
    if (job.status === 'thinking') return json(200, { status: 'thinking', text: '' });
    jobs.delete(id);
    return json(200, { status: job.status, text: job.text });
  }

  if (url.pathname === '/say' && req.method === 'POST') {
    let raw = '';
    req.on('data', c => { raw += c; });
    req.on('end', async () => {
      let text = '', quiet = false;
      try {
        const b = JSON.parse(raw || '{}');
        text = String(b.text || '').trim();
        quiet = !!b.quiet;
      } catch { }
      if (!text) return json(400, { error: 'empty' });
      const id = String(++seq);
      jobs.set(id, { status: 'thinking', text: '' });
      activity('thinking', '');
      append({ role: 'user', text, at: Date.now() });
      json(200, { id });
      try {
        const { reply, did } = await agentLoop(text);
        append({ role: 'assistant', text: reply, at: Date.now() });
        traceAction('done (' + (did.length ? did.join(',') : '没动手') + '): ' + reply.slice(0, 120));
        activity('idle', '');
        // 面板发来的（quiet）：回复直接进面板，别再写 say.txt ——
        // 写了会被鱼头顶的气泡监听再递一遍，一次发送显示两条
        if (!quiet) say(reply);
        jobs.set(id, { status: 'done', text: reply });
      } catch (err) {
        const msg = '（我这边卡住了：' + String(err.message || err).slice(0, 200) + '）';
        traceAction('error: ' + msg);
        activity('error', String(err.message || err).slice(0, 60));
        jobs.set(id, { status: 'error', text: msg });
      }
    });
    return;
  }

  // 他回到桌前：让她先说一句「你不在的时候我做了什么」。
  // 不是定时问候 —— 是给他一个落点：人回来，先知道刚才发生过什么。
  if (url.pathname === '/welcome') {
    const since = Number(url.searchParams.get('since') || 0);
    const mins = since ? Math.max(1, Math.round((Date.now() - since) / 60000)) : 0;
    (async () => {
      try {
        activity('thinking', '');
        const msg = await callModel([
          { role: 'system', content: systemPrompt() },
          {
            role: 'user', content:
              `（系统提示，不是他说的）他离开电脑 ${mins} 分钟，刚回来、刚双击你打开这个框。` +
              '用一两句话说你在这段时间里做了什么、或者注意到了什么具体的事 —— ' +
              '从上面的简报 / 台账 / 面板记录里挑一件真发生过的，别编。不要问他去干什么了，不要列清单，不要超过四十字。',
          },
        ], true);
        const text = String(msg.content || '').trim();
        if (!text) throw new Error('empty');
        append({ role: 'assistant', text, at: Date.now() });
        activity('idle', '');
        return json(200, { ok: true, text, mins });
      } catch (err) {
        activity('idle', '');
        return json(200, { ok: false, text: '', error: String(err.message || err).slice(0, 160) });
      }
    })();
    return;
  }

  json(404, { error: 'unknown' });
});

server.listen(PORT, '127.0.0.1', () => {
  console.log('[desk] bridge on http://127.0.0.1:' + PORT + ' (tools=' + TOOLS.length + ')');
});
