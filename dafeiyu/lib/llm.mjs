// dafeiyu/lib/llm.mjs —— 面板、心跳共用的模型客户端。
//
// 为什么要有这一个文件（2026-10-20 他问出来的）：
// 原来桌面这条线和心跳各自写死了 `api.siliconflow.cn` + `~/.dsh/siliconflow-key.txt`。
// 结果「硅基流动余额为零」把三件事一起打哑：面板对话、后台主动开口、语音。
// 他的判断是对的 —— 对话该走**自己的模型账号**（一个地方充钱），第三方只在真需要时用。
//
// 现在端点只有一个来源，按下面的顺序解析：
//   1. dafeiyu/state/llm.json（本机文件，.gitignore 挡着）：
//        { "provider": "deepseek", "baseUrl": "https://api.deepseek.com/v1",
//          "model": "deepseek-chat", "apiKeyFile": "~/.dsh/deepseek-key.txt" }
//      也可以直接写 "apiKey": "sk-..."（不推荐：文件权限再紧也不如单独一个 key 文件）
//   2. 环境变量 DAFEIYU_LLM_PROVIDER / BASE_URL / MODEL / KEY_FILE
//   3. 自动：有 ~/.dsh/deepseek-key.txt 就走 DeepSeek 官方，否则退回硅基流动（老行为）
//
// 两家都是 OpenAI 兼容的 /chat/completions，函数调用走同一套 tools 字段，所以下面只有一份实现。
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
export const ROOT = path.resolve(HERE, '..', '..');          // dafeiyu/lib -> 项目根
const CONFIG_FILE = path.join(ROOT, 'dafeiyu', 'state', 'llm.json');

const KNOWN = {
  deepseek: {
    label: 'DeepSeek 官方',
    baseUrl: 'https://api.deepseek.com/v1',
    model: 'deepseek-chat',
    keyFile: '~/.dsh/deepseek-key.txt',
  },
  siliconflow: {
    label: '硅基流动',
    baseUrl: 'https://api.siliconflow.cn/v1',
    model: 'deepseek-ai/DeepSeek-V4.1-Flash',
    keyFile: '~/.dsh/siliconflow-key.txt',
  },
};

// ---- 超时与重试（2026-10-21 他说的「刚刚卡住了，加一下超时重试吧」）----
// 以前 chat() 里一个上限都没有：一次挂住的 fetch 会让面板永远停在「在想」、
// 心跳那条 line 一直吊着（undici 自带的 headersTimeout 是 5 分钟，等于没救）。
// 现在每次请求 45 秒封顶；网络 / 超时 / 5xx / 429 再给一次机会（退避 1.2 秒），
// key 错和余额不足**不重试** —— 那两种错再试三遍也是一样的结果，只会让他多等。
const TIMEOUT_MS = Number(process.env.DAFEIYU_LLM_TIMEOUT_SEC || 45) * 1000;
const RETRIES_RAW = process.env.DAFEIYU_LLM_RETRIES;
const RETRIES = RETRIES_RAW === undefined || RETRIES_RAW === '' ? 1 : Math.max(0, Number(RETRIES_RAW) || 0);

const sleep = (ms) => new Promise(r => setTimeout(r, ms));

/** 1500 → "1.5"，45000 → "45"（别把 1.5 秒说成 2 秒） */
const secOf = (ms) => String(Math.round(ms / 100) / 10);

/** 这个错值不值得再试一次。 */
function retryable(e) {
  const m = String((e && e.message) || e || '');
  if (/^(NOKEY|KEY|BALANCE):/.test(m)) return false;   // 换 key / 充钱才行，重试没意义
  if (/^RATE:/.test(m)) return true;                    // 限流，等一下可能就通
  if (/^(TIMEOUT|NET):/.test(m)) return true;           // 网络抖动
  if (/^http 5\d\d/.test(m)) return true;               // 服务端自己出问题
  return false;
}

function expandHome(p) {
  const s = String(p || '');
  if (s === '~') return os.homedir();
  if (s.startsWith('~/') || s.startsWith('~\\')) return path.join(os.homedir(), s.slice(2));
  return s;
}

function readKeyFile(p) {
  try { return fs.readFileSync(expandHome(p), 'utf8').trim(); } catch { return ''; }
}

function readConfigFile() {
  try { return JSON.parse(fs.readFileSync(CONFIG_FILE, 'utf8')); } catch { return null; }
}

/** 解析出这次要用哪个端点。结果里有 provider / label / baseUrl / model / apiKey / keyFile。 */
export function llmConfig() {
  const file = readConfigFile() || {};
  const env = process.env;

  // 没写 provider 就自己挑：DeepSeek 有 key 就用官方，否则退回硅基流动（保持老行为，不至于突然全哑）。
  let provider = file.provider || env.DAFEIYU_LLM_PROVIDER || '';
  if (!provider) {
    provider = readKeyFile(KNOWN.deepseek.keyFile) ? 'deepseek' : 'siliconflow';
  }
  const preset = KNOWN[provider] || KNOWN.deepseek;

  const baseUrl = String(file.baseUrl || env.DAFEIYU_LLM_BASE_URL || preset.baseUrl).replace(/\/+$/, '');
  const model = String(file.model || env.DAFEIYU_LLM_MODEL || preset.model);
  const keyFile = file.apiKeyFile || env.DAFEIYU_LLM_KEY_FILE || preset.keyFile;
  const apiKey = String(file.apiKey || env.DAFEIYU_LLM_KEY || readKeyFile(keyFile) || '');

  return {
    provider,
    label: (KNOWN[provider] && KNOWN[provider].label) || provider,
    baseUrl,
    model,
    keyFile: expandHome(keyFile),
    apiKey,
  };
}

/** 把 HTTP 失败翻成人话（面板和心跳都靠这几个前缀分辨）。 */
function mapError(status, j) {
  const code = j && (j.code !== undefined ? j.code : (j.error && j.error.code));
  const why = String((j && (j.message || (j.error && j.error.message))) || '');
  if (status === 402 || code === 30001 || /balance|insufficient|余额/i.test(why)) {
    // 带上是谁的钱不够 —— 以前只报「余额不足」，还得再去猜是哪家。
    const c = llmConfig();
    return new Error('BALANCE: ' + c.label + '（' + c.model + '）余额不足');
  }
  if (status === 401 || status === 403) {
    const c = llmConfig();
    return new Error('KEY: ' + c.label + ' 拒绝了这个 key（http ' + status + '，看 ' + c.keyFile + '）');
  }
  if (status === 429) return new Error('RATE: 被限流了，等一两分钟再试（http 429）');
  return new Error('http ' + status + ' ' + JSON.stringify(j).slice(0, 200));
}

/** 一次请求，带硬超时。调用方给的 signal 和超时用 AbortSignal.any 合成一个。 */
async function requestOnce(c, body, timeoutMs, outer) {
  const to = AbortSignal.timeout(timeoutMs);
  const signal = outer ? AbortSignal.any([outer, to]) : to;
  let r;
  try {
    r = await fetch(c.baseUrl + '/chat/completions', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer ' + c.apiKey },
      body: JSON.stringify(body),
      signal,
    });
  } catch (e) {
    if (outer && outer.aborted) throw e;      // 外层自己掐的（心跳到点了），原样往外抛
    if (to.aborted) {
      throw new Error('TIMEOUT: ' + secOf(timeoutMs) + ' 秒没等到 ' + c.label +
        ' 回话（网络卡住，或那边在排队）');
    }
    throw new Error('NET: 连不上 ' + c.label + '（' + String((e && e.message) || e).slice(0, 160) + '）');
  }
  let j = {};
  try {
    j = await r.json();
  } catch (e) {
    // 回话读到一半断了：也按超时算，不然会掉进下面那个「empty message」里，看不出是网络问题
    if (to.aborted) throw new Error('TIMEOUT: ' + secOf(timeoutMs) + ' 秒只等到半截回话，断了');
    j = {};
  }
  if (!r.ok) throw mapError(r.status, j);
  const msg = j?.choices?.[0]?.message;
  if (!msg) throw new Error('empty message ' + JSON.stringify(j).slice(0, 200));
  return msg;
}

/**
 * 调一次模型，返回原始 message（含 content / tool_calls）。
 * opts: { tools, temperature, maxTokens, signal, timeoutMs, retries }
 * 值得再试的错最多试 1 + retries 次（默认 1 次）；key / 余额那种立刻抛，别让他白等。
 */
export async function chat(messages, opts = {}) {
  const c = llmConfig();
  if (!c.apiKey) {
    throw new Error('NOKEY: 找不到模型 key（应该在 ' + c.keyFile + '）。' +
      '把 DeepSeek 的 key 存进去就通了；不想用别家也可以改 dafeiyu/state/llm.json。');
  }
  const body = {
    model: c.model,
    messages,
    temperature: opts.temperature === undefined ? 0.6 : opts.temperature,
    max_tokens: opts.maxTokens || 900,
  };
  if (opts.tools && opts.tools.length) {
    body.tools = opts.tools;
    body.tool_choice = 'auto';
  }
  const timeoutMs = Number(opts.timeoutMs) > 0 ? Number(opts.timeoutMs) : TIMEOUT_MS;
  const tries = opts.retries === undefined ? RETRIES : Math.max(0, Number(opts.retries) || 0);

  let last;
  for (let i = 0; i <= tries; i++) {
    // 外层已经掐了就别再起新请求 —— 心跳到点的时候这一条最要紧
    if (opts.signal && opts.signal.aborted) throw opts.signal.reason || new Error('aborted');
    try {
      return await requestOnce(c, body, timeoutMs, opts.signal);
    } catch (e) {
      last = e;
      if (i >= tries || !retryable(e)) throw e;
      await sleep(1200 * (i + 1));
    }
  }
  throw last;
}

/** 给人看的一行状态（面板启动时打一次，省得又猜「现在用的是哪家」）。 */
export function llmSummary() {
  const c = llmConfig();
  return {
    provider: c.provider,
    label: c.label,
    model: c.model,
    baseUrl: c.baseUrl,
    hasKey: !!c.apiKey,
    keyFile: c.keyFile,
    timeoutSec: Math.round(TIMEOUT_MS / 1000),
    retries: RETRIES,
  };
}
