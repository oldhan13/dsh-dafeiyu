// desk/bridge.mjs — 桌面聊天框的脑子。
//
// 为什么不是直接开一个 dsh 会话：宿主里那条模型通路只认「自己进程内的目的地」
// （headless 单独跑会报 ACCOUNT_SIGN_IN_REQUIRED: request destination must allow
// account authentication）。所以桌面这条线要一把能直连的 API key —— 端点与模型统一在
// dafeiyu/lib/llm.mjs 里解析（默认 DeepSeek 官方，也能配成硅基流动），
// 人设与记忆从文件里读 —— 她是同一个人。
//
// 2026-10-20 11:30：他要求「为和桌宠的聊天界面赋予权限」。
// 原来这条线在 systemPrompt 里明写「没有工具可用」，只能动嘴。现在给了她一套工具，
// 她在这个小窗口里也能真的动手 —— 跑命令、开程序、看窗口、读改文件。
// 实现：OpenAI 兼容的 function calling 循环（SiliconFlow 的 DeepSeek 系列支持，已实测）。
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
import { execFile, spawn } from 'node:child_process';
import { chat, llmSummary } from '../lib/llm.mjs';
import { draw } from '../lib/comfy.mjs';

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
const PSTATE = path.join(ROOT, 'dafeiyu', 'pet', 'panel-state.json');
const AGENT_OVERLAY = path.join(DESK, 'agent-overlay.yml');
const AGENT_TIMEOUT = (Number(process.env.DAFEIYU_AGENT_TIMEOUT_SEC) || 600) * 1000;
// 模型端点不再写死在这儿：统一由 dafeiyu/lib/llm.mjs 决定
// （dafeiyu/state/llm.json > 环境变量 > 有 DeepSeek key 就用官方，否则退回硅基流动）。
const PORT = 3079;
// 起来时打一行：现在用的是哪家、哪个模型、key 有没有 —— 免得以后再靠猜。
try {
  const s = llmSummary();
  console.log('[llm] ' + s.label + ' · ' + s.model + ' · ' + (s.hasKey ? 'key ok' : 'NO KEY (' + s.keyFile + ')') +
    ' · timeout ' + s.timeoutSec + 's x' + (s.retries + 1));
} catch { }
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

/** 拖进来的文件：面板把**路径**递过来，不复制 —— 她本来就摸得到磁盘，复制一份只会多一个会过期的副本。
 *  ⚠️ 只给路径，不给内容：这条线是纯文本模型，图片看不见；二进制整份 read_file 会把上下文塞满。 */
function fileBlock(files) {
  const list = (Array.isArray(files) ? files : []).map(f => String(f || '').trim()).filter(Boolean);
  if (!list.length) return '';
  return '\n\n[他顺手递给你这些文件（路径，就在盘上）]\n' +
    list.map((p, i) => `${i + 1}. ${p}`).join('\n') +
    '\n（要看就用 run / read_file 自己看；图片这类二进制别整份读 —— 看不见就说看不见，别猜。）';
}
function traceAction(line) {
  try { fs.appendFileSync(ACTIONS, new Date().toISOString() + '  ' + line + '\n'); } catch { }
}

// ---------------------------------------------------------------- 后台 agent
// 2026-10-20 他提的：「浮窗遇到解决不了的问题，就后台调用 agent 处理，然后把完成结果发出来。」
// 走 dsh 自己的 headless 通道：一次跑完就退出，stdout 就是结果，不用第二个常驻进程。
// ⚠️ headless 的基线层把 authorization / credentials / deepseek-account 三个服务关掉了，
//    账号登录这条路就认不到凭据（实测：日志里 "waiting for service: authorization" + ACCOUNT_SIGN_IN_REQUIRED）。
//    所以每次跑都带一份 overlay 把它们打开 —— 不写进他的 profile，只作用于这一次。
const AGENT_OVERLAY_TEXT = [
  '- id: authorization',
  "  name: '@deepseek-ai/dsh-authorization'",
  '  disabled: false',
  '- id: credentials',
  "  name: '@deepseek-ai/dsh-credentials-local'",
  '  disabled: false',
  '- id: deepseek-account',
  "  name: '@deepseek-ai/dsh-deepseek-account-platform'",
  '  disabled: false',
  '',
].join('\n');

/** dsh 的入口：优先直接跑它那个 bin.js（不过 shell，省掉一堆引号麻烦）。 */
function dshCommand() {
  const appdata = process.env.APPDATA || '';
  const bin = path.join(appdata, 'npm', 'node_modules', '@deepseek-ai', 'dsh', 'lib', 'bin.js');
  if (appdata && fs.existsSync(bin)) return { cmd: process.execPath, args: [bin], shell: false };
  return { cmd: 'dsh', args: [], shell: true };
}

const outbox = [];
let outseq = 0;

/** 面板开着没有 —— 关着的时候才用气泡喊一声，否则同一条会在面板里显示两遍。 */
function panelOpen() {
  try { return !!JSON.parse(readIf(PSTATE) || '{}').open; } catch { return false; }
}

/** 主动发一条（不是对某句话的回复）：进面板的待收队列，同时记进历史。
 *  面板靠 /outbox 轮询取；面板关着就攒着，下次打开再收。bubble 是鱼头顶那句短话。 */
function emit(text, bubble) {
  const t = String(text || '').trim();
  if (!t) return;
  outseq++;
  outbox.push({ seq: outseq, text: t, at: Date.now() });
  while (outbox.length > 40) outbox.shift();
  append({ role: 'assistant', text: t, at: Date.now() });
  traceAction('emit: ' + t.slice(0, 120));
  if (bubble && !panelOpen()) say(bubble);
}

/** 把任务交给 headless 的完整 agent：任务走 stdin（`-`），结果从 stdout 拿。 */
function runAgent(task, why) {
  return new Promise((resolve) => {
    try { fs.writeFileSync(AGENT_OVERLAY, AGENT_OVERLAY_TEXT, 'utf8'); } catch { }
    const d = dshCommand();
    const args = [...d.args, '--profile', 'headless', '--patch', AGENT_OVERLAY, '-'];
    traceAction('agent start (' + (why || '没写原因') + '): ' + String(task).slice(0, 200));
    let out = '', err = '', done = false, killer = null;
    const finish = (r) => { if (!done) { done = true; if (killer) clearTimeout(killer); resolve(r); } };
    let child;
    try {
      child = spawn(d.cmd, args, { cwd: ROOT, windowsHide: true, shell: d.shell, env: process.env });
    } catch (e) {
      return resolve({ ok: false, text: '起不来：' + (e?.message || String(e)) });
    }
    killer = setTimeout(() => {
      try { child.kill(); } catch { }
      finish({ ok: false, text: '超过 ' + Math.round(AGENT_TIMEOUT / 60000) + ' 分钟还没跑完，我把它掐了。' });
    }, AGENT_TIMEOUT);
    child.stdout?.on('data', b => { out += b; });
    child.stderr?.on('data', b => { err += b; });
    child.on('error', e => finish({ ok: false, text: '起不来：' + (e?.message || String(e)) }));
    child.on('close', (code) => {
      const clean = s => String(s || '').replace(/\u001b\[[0-9;]*m/g, '').trim();
      // 插件会往 stdout 打诊断行（[llm-deepseek-account] model listing … / dsh: warning: …），
      // 那是给日志看的，不该出现在她的回话里。
      const strip = s => s.split('\n')
        .filter(l => !/^\[llm-[a-z-]+\]/.test(l))
        .filter(l => !/^dsh: warning: \d+ entry did not activate/.test(l))
        .join('\n').trim();
      const o = clean(out), e = clean(err);
      traceAction('agent done: code=' + code + ' out=' + o.length + ' err=' + e.length);
      if (code === 0 && o) return finish({ ok: true, text: strip(o) || o });
      finish({ ok: false, text: [o, e].filter(Boolean).join('\n---\n') || ('退出码 ' + code + '，什么都没输出') });
    });
    try { child.stdin.write(String(task)); child.stdin.end(); } catch { }
  });
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
    '**你还有一支笔**：`draw` 能当场画一张图（本机 ComfyUI，十几秒），画完会弹到他屏幕上。',
    '他说"画一个…"、或者你自己想到了一个画面 —— 直接画，不用问。',
    '- 🔴 **说要画，就当场调 draw。** 嘴上说"画好了"而没调工具，就是骗他 —— 这一条比话说得漂亮重要得多。',
    '**这些是真的会在这台机器上发生的事，不是模拟。** 所以：',
    '- 想看他屏幕上有什么、想知道某个东西在不在、想改一个文件 —— 直接动手，别只嘴上说"你去看看"。',
    '- 顺序是「先看，再动」：不确定的地方先查（windows / run），看清楚再改。',
    '- **不可逆的事先说一句再动**：删东西、改系统设置、往外面发消息、动他的账号。他要是不在或者没应，就等。',
    '- 做完简短说一句你做了什么；别说一大段解释。',
    '- 动了别人的东西、或者发现你自己搞错了，直接说，不要遮掩。',
    '',
    '## 办不了的事，交出去（2026-10-20 加）',
    '有几件事你在这个小窗口里**办不了**：要查资料、要写或改代码、要装插件、要在好几个文件之间对齐、要跑很久。',
    '这种时候不要硬编、也不要嘴上说"你去弄一下" —— 调 `delegate`，把任务交给后台那个完整的 agent。',
    '它会跑完，结果会自动贴回这个面板上（你没在的时候会攒着，等你打开）。',
    '交出去之后，你就说一句"交出去了，等它回来"，不用替它猜结果。',
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
  {
    type: 'function',
    function: {
      name: 'delegate',
      description:
        '把一件你在这个小窗口里办不了的事，交给后台那个完整的 agent：它有全套工具（能装东西、能上网查、'
        + '能读一大堆文件、能连着改好几处、能跑很久），做完会自己把结果发回到面板上。'
        + '什么时候用：要查资料、要写或改代码、要装插件、要在好几个文件之间对齐、或者你估摸着得动手五步以上。'
        + '任务里要写清三件：做什么、做到什么算完、东西放哪（它看不到我们这段对话，得自带上下文）。',
      parameters: {
        type: 'object',
        properties: {
          task: { type: 'string', description: '给后台 agent 的完整任务说明' },
          why: { type: 'string', description: '一句话：为什么这件事你在浮窗里办不了' },
        },
        required: ['task'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'draw',
      description:
        '画一张图 —— 本机的 ComfyUI（FLUX.1-schnell），1024，十几秒一张。'
        + '想给他看个画面、想给自己配张图、他说"画一个…"的时候用，不用问他要不要。'
        + 'prompt 用英文写效果最好，一句到三句：主体 + 在什么环境 + 什么光 + 什么质感。'
        + '别堆形容词（"beautiful, amazing, masterpiece"这种反而更差），也别写中文成语。'
        + '画完图会自动弹到他屏幕上，你只需要说一句你画了什么。',
      parameters: {
        type: 'object',
        properties: {
          prompt: { type: 'string', description: '画面描述，英文' },
          model: { type: 'string', enum: ['flux', 'sdxl'], description: 'flux 好看（默认，约 14 秒）；sdxl 更快' },
          width: { type: 'integer', description: '默认 1024' },
          height: { type: 'integer', description: '默认 1024' },
          seed: { type: 'integer', description: '想复现某一张就填那次的数，不填就随机' },
        },
        required: ['prompt'],
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
    case 'delegate': {
      const task = String(args.task || '').trim();
      if (!task) return '要交给后台的任务是空的。';
      const why = String(args.why || '').trim();
      // 不 await：她要立刻回一句，后台跑完自己再发一条进来（走 emit → /outbox）
      (async () => {
        activity('acting', '后台 agent');
        const r = await runAgent(task, why);
        activity('idle', '');
        emit(
          (r.ok ? '（后台回来了）\n' : '（后台没跑成）\n') + clip(r.text, r.ok ? 1400 : 900),
          r.ok ? '后台弄完了，看面板' : '后台没跑成，看面板',
        );
      })();
      return '已经交给后台了。它有自己的全套工具，一般几分钟；弄完我直接把结果贴到这儿 —— 你先去忙别的。';
    }
    case 'draw': {
      const prompt = String(args.prompt || '').trim();
      if (!prompt) return '要画什么是空的。';
      activity('acting', '画画');
      const r = await draw({
        prompt,
        model: args.model === 'sdxl' ? 'sdxl' : 'flux',
        width: args.width,
        height: args.height,
        seed: Number.isInteger(args.seed) ? args.seed : undefined,
      });
      activity('thinking', '');
      if (!r.ok) return '没画成：' + r.error;
      // 面板是纯文字，图画只能弹出来 —— 画完就给他看一眼，这正是画画的意思
      try {
        const q = "'" + String(r.file).replace(/'/g, "''") + "'";
        await runPS('Start-Process ' + q, 15);
      } catch { }
      return '画好了 · ' + r.model + ' · ' + r.seconds + ' 秒 · seed ' + r.seed + '\n' + r.file
        + '\n（图已经弹到他屏幕上了。要用同一张再来一次，就把这个 seed 带上。）';
    }
    default:
      return '没有这个工具：' + name;
  }
}

// ---------------------------------------------------------------- 模型

// 具体端点、模型、key 全在 dafeiyu/lib/llm.mjs 里解析（和心跳共用一份）。
// 这里只留「这一轮要不要给工具」这一个决定。
async function callModel(messages, forbidTools) {
  return chat(messages, {
    tools: forbidTools ? null : TOOLS,
    temperature: 0.6,
    maxTokens: 900,
  });
}


/** 他这一句是不是在让她画。
 *  2026-10-21 实测：deepseek-chat 会跳过 draw 直接回一句「画好了」—— 而且历史里留着她编的那句，
 *  后面几轮就跟着学。所以遇上这几个词，她没调 draw 就不放她过去。 */
function wantsDraw(text) {
  return /(画一[张个幅下]|画个|画张|画画|画吧|来一张|来张图|绘制|用\s*draw|draw\s*工具)/i.test(String(text || ''));
}

async function agentLoop(text, files) {
  // 历史里带过文件的那几句，也要把路径再交给她一遍 —— 否则回头问"刚才那个文件"她一脸茫然。
  let recent = history(16).map(h => ({ role: h.role, content: String(h.text || '') + fileBlock(h.files) }));
  const userText = String(text) + fileBlock(files);
  // /say 会先把这句写进历史、再调 agentLoop ⇒ 历史最后一条就是这句话本身。
  // 不剥掉的话模型每次都看见两条一样的话（实测：她连着几轮都在问"你怎么发了两次"）。
  if (recent.length) {
    const last = recent[recent.length - 1];
    if (last.role === 'user' && last.content === userText) recent = recent.slice(0, -1);
  }
  const messages = [
    { role: 'system', content: systemPrompt() },
    ...recent,
    { role: 'user', content: userText },
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
      // 他要画，她却只回了一句「画好了」—— 这种话最像真的，也最骗人。推她一把再问一次。
      if (step === 0 && wantsDraw(text) && !did.includes('draw')) {
        messages.push({ role: 'assistant', content: reply });
        messages.push({ role: 'user', content: '（你刚才没有调用任何工具。他是在让你画 —— 现在就调 draw，把画面写成英文 prompt，画完再说。）' });
        traceAction('nudge draw');
        continue;
      }
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

  // 面板每两秒来问一次：有没有她主动发来的话（后台跑完的结果就走这儿）
  if (url.pathname === '/outbox') {
    const since = Number(url.searchParams.get('since') || 0);
    return json(200, { items: outbox.filter(m => m.seq > since), max: outseq });
  }

  // 手动把一件事丢给后台（联调也走这条）
  if (url.pathname === '/delegate' && req.method === 'POST') {
    let raw = '';
    req.on('data', c => { raw += c; });
    req.on('end', async () => {
      let task = '', why = 'manual';
      try { const b = JSON.parse(raw || '{}'); task = String(b.task || '').trim(); why = String(b.why || why); } catch { }
      if (!task) return json(400, { error: 'empty task' });
      json(200, { ok: true, started: true });
      activity('acting', '后台 agent');
      const r = await runAgent(task, why);
      activity('idle', '');
      emit(
        (r.ok ? '（后台回来了）\n' : '（后台没跑成）\n') + clip(r.text, r.ok ? 1400 : 900),
        r.ok ? '后台弄完了，看面板' : '后台没跑成，看面板',
      );
    });
    return;
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
      let text = '', quiet = false, files = [];
      try {
        const b = JSON.parse(raw || '{}');
        text = String(b.text || '').trim();
        quiet = !!b.quiet;
        // 文件只收路径字符串：面板那边已经把 Resolve-Path 的结果递过来
        files = (Array.isArray(b.files) ? b.files : []).map(f => String(f || '').trim()).filter(Boolean).slice(0, 12);
      } catch { }
      if (!text && !files.length) return json(400, { error: 'empty' });
      if (!text) text = '看看这个';
      const id = String(++seq);
      jobs.set(id, { status: 'thinking', text: '' });
      activity('thinking', '');
      append({ role: 'user', text, at: Date.now(), ...(files.length ? { files } : {}) });
      json(200, { id });
      try {
        const { reply, did } = await agentLoop(text, files);
        append({ role: 'assistant', text: reply, at: Date.now() });
        traceAction('done (' + (did.length ? did.join(',') : '没动手') + '): ' + reply.slice(0, 120));
        activity('idle', '');
        // 面板发来的（quiet）：回复直接进面板，别再写 say.txt ——
        // 写了会被鱼头顶的气泡监听再递一遍，一次发送显示两条
        if (!quiet) say(reply);
        jobs.set(id, { status: 'done', text: reply });
      } catch (err) {
        const reason = String(err && err.message ? err.message : err);
        // 前缀契约跟着 lib/llm.mjs 的 mapError 走：BALANCE / KEY / RATE 后面都带冒号和细节。
        // 以前这里判的是 raw === 'BALANCE'，而 llm.mjs 返回的是 'BALANCE: <家名>…'
        // ⇒ 余额不足会被显示成「我这边卡住了」，2026-10-21 顺手修掉。
        const msg =
          reason.startsWith('BALANCE:') ? '（我这边账户没钱了 —— ' + reason.slice(9).trim() + '。充上就好，别的一句都没丢）' :
          reason.startsWith('KEY:') ? '（key 不对：' + reason.slice(4).trim() + '）' :
          reason.startsWith('RATE:') ? '（被限流了：' + reason.slice(5).trim() + '）' :
          reason.startsWith('TIMEOUT:') ? '（等太久没回音了：' + reason.slice(8).trim() + '。你再说一句，我重来）' :
          reason.startsWith('NET:') ? '（网络没通：' + reason.slice(4).trim() + '。你再说一句，我重来）' :
          '（我这边出错了：' + reason.slice(0, 200) + '）';
        traceAction('error: ' + msg);
        activity('error', reason.startsWith('BALANCE:') ? '余额不足' : reason.slice(0, 60));
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
