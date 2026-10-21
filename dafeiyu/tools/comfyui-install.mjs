// dafeiyu/tools/comfyui-install.mjs
//
// 一条命令把 ComfyUI 从「什么都没下」做到「画出一张图」。
// 2026-10-21 凌晨他要的：别让我盯着，你自己把后面的活串起来；然后「按我机器能力跑个好点的模型」。
//
//   node dafeiyu/tools/comfyui-install.mjs                # 一路做完（幂等，重跑只补没做完的）
//   node dafeiyu/tools/comfyui-install.mjs --model flux   # 只准备 FLUX.1-schnell
//   node dafeiyu/tools/comfyui-install.mjs --start        # 只启动
//   node dafeiyu/tools/comfyui-install.mjs --draw "..."   # 只画一张（用默认模型）
//   node dafeiyu/tools/comfyui-install.mjs --draw "..." --model sdxl
//
// 阶段：① 补齐文件 ② 解压 ③ 模型就位 ④ 起服务 ⑤ 画一张验收。每阶段先看现状，做过就跳过。
//
// 目录（他定的：D 盘、自己一个文件夹、不往根目录扔东西）：
//   D:\ComfyUI\downloads  下载中转
//   D:\ComfyUI\app        portable 解压后（app\ComfyUI\...）
//   D:\ComfyUI\output     她画的图
//   D:\ComfyUI\logs       安装与运行日志
//
// 模型怎么选（16 GB 显存 / Blackwell 这一档）：
//   FLUX.1-schnell fp8 是这台机器能舒服跑的上限 —— 4 步出图，质量明显高过 SDXL。
//   它的 fp8 权重 16 GB 正好卡在显存边上，ComfyUI 会 offload 一部分到内存，1024 一张十秒上下，可以接受。
//   SDXL 留着当基准：权重大小是把 Flux 的一半，秒出，用来确认管线没坏。
import fs from 'node:fs';
import path from 'node:path';
import { spawn, spawnSync } from 'node:child_process';

const ROOT = process.env.COMFY_ROOT || 'D:\\ComfyUI';
const DL = path.join(ROOT, 'downloads');
const APP = path.join(ROOT, 'app');
const LOGS = path.join(ROOT, 'logs');
const OUT = path.join(ROOT, 'output');
const SEVEN = process.env.SEVEN_ZIP || 'C:\\dsh-temp\\7zr.exe';
const PORT = Number(process.env.COMFY_PORT || 8188);
const PROXY = process.env.DAFEIYU_PROXY || 'http://127.0.0.1:7897';

const PORTABLE = path.join(DL, 'ComfyUI_windows_portable.7z');
const PORTABLE_BYTES = 2018444114;

for (const d of [ROOT, DL, LOGS, OUT]) fs.mkdirSync(d, { recursive: true });
const LOGFILE = path.join(LOGS, 'install.log');

function log(msg) {
  const line = '[' + new Date().toLocaleString('sv-SE', { timeZone: 'Asia/Hong_Kong' }) + '] ' + msg;
  console.log(line);
  try { fs.appendFileSync(LOGFILE, line + '\n', 'utf8'); } catch { }
}
const mb = (n) => (n / 1048576).toFixed(0) + ' MB';
const gb = (n) => (n / 1073741824).toFixed(2) + ' GB';
const sleep = (ms) => new Promise(r => setTimeout(r, ms));
const sizeOf = (f) => { try { return fs.statSync(f).size; } catch { return 0; } };

// ---------------------------------------------------------------- 模型清单
// 全部走 hf-mirror 直连（5.2 MB/s）。GitHub 那套模型仓要 token，403。
const HM = 'https://hf-mirror.com';
const MODELS = {
  sdxl: {
    label: 'SDXL base 1.0',
    files: [
      { url: HM + '/stabilityai/stable-diffusion-xl-base-1.0/resolve/main/sd_xl_base_1.0.safetensors', name: 'sd_xl_base_1.0.safetensors', dir: 'checkpoints' },
    ],
    graph: () => ({
      '4': { class_type: 'CheckpointLoaderSimple', inputs: { ckpt_name: 'sd_xl_base_1.0.safetensors' } },
      '5': { class_type: 'EmptyLatentImage', inputs: { width: 1024, height: 1024, batch_size: 1 } },
      '6': { class_type: 'CLIPTextEncode', inputs: { text: '', clip: ['4', 1] } },
      '7': { class_type: 'CLIPTextEncode', inputs: { text: 'blurry, low quality, watermark, text', clip: ['4', 1] } },
      '3': {
        class_type: 'KSampler', inputs: {
          seed: 12345, steps: 28, cfg: 7.0, sampler_name: 'dpmpp_2m', scheduler: 'karras', denoise: 1.0,
          model: ['4', 0], positive: ['6', 0], negative: ['7', 0], latent_image: ['5', 0],
        },
      },
      '8': { class_type: 'VAEDecode', inputs: { samples: ['3', 0], vae: ['4', 2] } },
      '9': { class_type: 'SaveImage', inputs: { filename_prefix: 'dfy-sdxl', images: ['8', 0] } },
    }),
  },
  flux: {
    label: 'FLUX.1-schnell fp8',
    files: [
      { url: HM + '/Comfy-Org/flux1-schnell/resolve/main/flux1-schnell-fp8.safetensors', name: 'flux1-schnell-fp8.safetensors', dir: 'diffusion_models' },
      { url: HM + '/comfyanonymous/flux_text_encoders/resolve/main/t5xxl_fp8_e4m3fn.safetensors', name: 't5xxl_fp8_e4m3fn.safetensors', dir: 'text_encoders' },
      { url: HM + '/comfyanonymous/flux_text_encoders/resolve/main/clip_l.safetensors', name: 'clip_l.safetensors', dir: 'text_encoders' },
      // black-forest-labs 的 ae.safetensors 是 gated（403），ModelScope 那份不用登录。
      { url: 'https://modelscope.cn/models/AI-ModelScope/FLUX.1-schnell/resolve/master/ae.safetensors', name: 'ae.safetensors', dir: 'vae', noProxy: true },
    ],
    // schnell 是 4 步、cfg 要 1.0、negative 留空 —— 照官方 workflow 抄的，别改成 20 步，那是 dev 的用法。
    graph: () => ({
      '1': { class_type: 'UNETLoader', inputs: { unet_name: 'flux1-schnell-fp8.safetensors', weight_dtype: 'default' } },
      '2': { class_type: 'DualCLIPLoader', inputs: { clip_name1: 't5xxl_fp8_e4m3fn.safetensors', clip_name2: 'clip_l.safetensors', type: 'flux' } },
      '3': { class_type: 'VAELoader', inputs: { vae_name: 'ae.safetensors' } },
      '4': { class_type: 'CLIPTextEncode', inputs: { text: '', clip: ['2', 0] } },
      '5': { class_type: 'CLIPTextEncode', inputs: { text: '', clip: ['2', 0] } },
      '6': { class_type: 'EmptyLatentImage', inputs: { width: 1024, height: 1024, batch_size: 1 } },
      '7': {
        class_type: 'KSampler', inputs: {
          seed: 12345, steps: 4, cfg: 1.0, sampler_name: 'euler', scheduler: 'simple', denoise: 1.0,
          model: ['1', 0], positive: ['4', 0], negative: ['5', 0], latent_image: ['6', 0],
        },
      },
      '8': { class_type: 'VAEDecode', inputs: { samples: ['7', 0], vae: ['3', 0] } },
      '9': { class_type: 'SaveImage', inputs: { filename_prefix: 'dfy-flux', images: ['8', 0] } },
    }),
  },
};
const DEFAULT_MODEL = 'flux';

// ---------------------------------------------------------------- ① 下载
function curlArgs(url, extra, useProxy) {
  const args = ['-L', '--no-progress-meter', ...extra];
  // 本机 GitHub 直连是不通的，三个镜像又都比代理慢；hf-mirror / modelscope 反过来，直连最快。
  if (useProxy) args.push('--proxy', PROXY);
  args.push(url);
  return args;
}

function runCurl(args) {
  return new Promise((resolve) => {
    const p = spawn('curl.exe', args, { stdio: ['ignore', 'ignore', 'pipe'], windowsHide: true });
    let err = '';
    p.stderr.on('data', (c) => { err += c.toString(); });
    p.on('close', (code) => resolve({ code, err: err.slice(-300) }));
  });
}

/** 问服务器要文件大小（跟 308 跳转）。拿不到就返回 0，调用方退回「按存在性判断」。 */
function headSize(url, useProxy) {
  return new Promise((resolve) => {
    const args = ['-sSIL', '--max-time', '40'];
    if (useProxy) args.push('--proxy', PROXY);
    args.push(url);
    const p = spawn('curl.exe', args, { windowsHide: true });
    let out = '';
    p.stdout.on('data', (c) => { out += c.toString(); });
    p.on('close', () => {
      const m = [...out.matchAll(/^content-length:\s*(\d+)/gim)];
      resolve(m.length ? Number(m[m.length - 1][1]) : 0);
    });
  });
}

async function ensureFile(url, file, useProxy, label) {
  const want = await headSize(url, useProxy);
  let have = sizeOf(file);
  if (want > 0 && have >= want) { log('✓ ' + label + ' · ' + gb(have)); return true; }
  log('↓ ' + label + ' · ' + gb(have) + ' / ' + (want ? gb(want) : '?'));
  for (let i = 0; i < 12; i++) {
    const r = await runCurl(curlArgs(url, [
      // GitHub 会在传到一半时掐连接（schannel: missing close_notify）；--retry 不认这类错，必须 --retry-all-errors。
      '--retry', '40', '--retry-all-errors', '--retry-delay', '2', '-C', '-', '-o', file,
    ], useProxy));
    have = sizeOf(file);
    log('  curl ' + r.code + ' · ' + gb(have) + (want ? ' / ' + gb(want) : '') + (r.err ? ' · ' + r.err.replace(/\s+/g, ' ').slice(0, 110) : ''));
    if (want > 0 && have >= want) { log('✓ ' + label + ' 好了'); return true; }
    if (want === 0 && have > 0 && r.code === 0) { log('✓ ' + label + ' 好了（大小未知）'); return true; }
    await sleep(2000);
  }
  return false;
}

// ---------------------------------------------------------------- ② 解压
function extractPortable() {
  const marker = path.join(APP, 'run_nvidia_gpu.bat');
  if (fs.existsSync(marker)) { log('✓ 已解压 · ' + APP); return true; }
  if (!fs.existsSync(SEVEN)) { log('缺少解压器：' + SEVEN); return false; }
  if (sizeOf(PORTABLE) < PORTABLE_BYTES) { log('压缩包还不完整，先别解压'); return false; }
  log('解压中（1.9 GB，几分钟）…');
  const t0 = Date.now();
  const r = spawnSync(SEVEN, ['x', '-y', '-o' + ROOT, PORTABLE], { stdio: ['ignore', 'ignore', 'pipe'], windowsHide: true });
  if (r.status !== 0) { log('解压失败 · ' + String(r.stderr || '').slice(-300)); return false; }
  const unzipped = path.join(ROOT, 'ComfyUI_windows_portable');
  if (fs.existsSync(unzipped) && !fs.existsSync(APP)) fs.renameSync(unzipped, APP);
  log('✓ 解压完成 · ' + Math.round((Date.now() - t0) / 1000) + 's');
  return fs.existsSync(marker);
}

// ---------------------------------------------------------------- ③ 模型就位
function placeModel(key) {
  const m = MODELS[key];
  let all = true;
  for (const f of m.files) {
    const dir = path.join(APP, 'ComfyUI', 'models', f.dir);
    fs.mkdirSync(dir, { recursive: true });
    const dst = path.join(dir, f.name);
    const src = path.join(DL, f.name);
    if (sizeOf(dst) > 0) { log('✓ 已就位 · ' + f.name); continue; }
    if (sizeOf(src) === 0) { log('✗ 还没下 · ' + f.name); all = false; continue; }
    try { fs.renameSync(src, dst); }
    catch { fs.copyFileSync(src, dst); fs.unlinkSync(src); }
    log('→ ' + f.name + ' 放进 ' + f.dir);
  }
  return all;
}

// ---------------------------------------------------------------- ④ 启动
async function stats() {
  try {
    const r = await fetch('http://127.0.0.1:' + PORT + '/system_stats', { signal: AbortSignal.timeout(3000) });
    return r.ok ? await r.json() : null;
  } catch { return null; }
}

async function ensureRunning() {
  if (await stats()) { log('✓ ComfyUI 在跑 · ' + PORT); return true; }
  const py = path.join(APP, 'python_embeded', 'python.exe');
  const main = path.join(APP, 'ComfyUI', 'main.py');
  if (!fs.existsSync(py)) { log('找不到 ' + py); return false; }
  const out = fs.openSync(path.join(LOGS, 'comfy.log'), 'a');
  const p = spawn(py, ['-s', main, '--windows-standalone-build', '--port', String(PORT)], {
    cwd: APP, detached: true, stdio: ['ignore', out, out], windowsHide: true,
  });
  p.unref();
  log('起了 ComfyUI · pid ' + p.pid);
  const t0 = Date.now();
  while (Date.now() - t0 < 240000) {
    if (await stats()) { log('✓ 就绪 · ' + Math.round((Date.now() - t0) / 1000) + 's'); return true; }
    await sleep(2000);
  }
  log('240 秒没就绪 —— 看 ' + path.join(LOGS, 'comfy.log'));
  return false;
}

// ---------------------------------------------------------------- ⑤ 画一张
async function draw(modelKey, prompt) {
  const graph = MODELS[modelKey].graph();
  // 正向提示词永远是 4 号节点以外那个 —— 两张图里正向都在 '4'，负向在 '5'（SDXL 是 '6'/'7'）。
  if (modelKey === 'sdxl') graph['6'].inputs.text = prompt; else graph['4'].inputs.text = prompt;
  const r = await fetch('http://127.0.0.1:' + PORT + '/prompt', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ prompt: graph, client_id: 'dafeiyu-install' }),
  });
  const j = await r.json().catch(() => ({}));
  if (!j.prompt_id) { log('被拒了 · ' + JSON.stringify(j).slice(0, 600)); return null; }
  log('工单 ' + j.prompt_id + '（' + MODELS[modelKey].label + '）');
  const t0 = Date.now();
  while (Date.now() - t0 < 600000) {
    await sleep(1500);
    const h = await fetch('http://127.0.0.1:' + PORT + '/history/' + j.prompt_id, { signal: AbortSignal.timeout(8000) })
      .then(x => x.json()).catch(() => ({}));
    const rec = h[j.prompt_id];
    if (!rec) continue;
    if (rec.status && rec.status.status_str === 'error') { log('出图出错 · ' + JSON.stringify(rec.status).slice(0, 500)); return null; }
    const imgs = rec.outputs && rec.outputs['9'] && rec.outputs['9'].images;
    if (imgs && imgs.length) {
      const img = imgs[0];
      const src = path.join(APP, 'ComfyUI', 'output', img.subfolder || '', img.filename);
      const dst = path.join(OUT, img.filename);
      try { fs.copyFileSync(src, dst); } catch { }
      const p = fs.existsSync(dst) ? dst : src;
      log('✓ 出图 · ' + Math.round((Date.now() - t0) / 1000) + 's · ' + p);
      return p;
    }
  }
  log('600 秒没出图');
  return null;
}

// ---------------------------------------------------------------- 主流程
const argv = process.argv.slice(2);
const argOf = (k) => { const i = argv.indexOf(k); return i >= 0 ? argv[i + 1] : null; };
const onlyStart = argv.includes('--start');
const ifDraw = argv.includes('--draw');
const drawPrompt = argOf('--draw');
const wantModel = argOf('--model');
const targets = wantModel ? [wantModel] : Object.keys(MODELS);

log('===== ComfyUI ===== ROOT=' + ROOT + ' · 模型 ' + targets.join('+'));

if (ifDraw) {
  if (!(await ensureRunning())) process.exit(1);
  const key = wantModel || DEFAULT_MODEL;
  const p = await draw(key, drawPrompt || 'a small orange fish swimming in dark water, soft rim light');
  process.exit(p ? 0 : 1);
}

if (!onlyStart) {
  if (!(await ensureFile(
    'https://github.com/Comfy-Org/ComfyUI/releases/latest/download/ComfyUI_windows_portable_nvidia.7z',
    PORTABLE, true, '本体'))) { log('本体没下完，停'); process.exit(1); }
  if (!extractPortable()) { log('解压没成功，停'); process.exit(1); }

  const ready = {};
  for (const key of targets) {
    const m = MODELS[key];
    let ok = true;
    for (const f of m.files) {
      // 模型全部直连（hf-mirror 5.2 MB/s、modelscope 也行）；走代理反而只有 1 MB/s 上下。
      const got = await ensureFile(f.url, path.join(DL, f.name), false, m.label + ' / ' + f.name);
      if (!got) ok = false;
    }
    ready[key] = ok && placeModel(key);
  }
  log('模型就绪：' + JSON.stringify(ready));
}

if (!(await ensureRunning())) process.exit(1);

// 验收：默认模型真画一张。画不出来就不算装好。
const first = MODELS[wantModel || DEFAULT_MODEL] ? (wantModel || DEFAULT_MODEL) : 'sdxl';
const img = await draw(first, 'a small orange fish swimming in dark water, soft rim light, minimal');
log('===== 完 =====');
log(img ? '第一张图：' + img : '服务起来了，但第一张图没出来');
process.exit(img ? 0 : 2);
