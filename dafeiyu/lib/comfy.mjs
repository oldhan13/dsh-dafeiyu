// dafeiyu/lib/comfy.mjs — 画一张图（本机的 ComfyUI，127.0.0.1:8188）。
//
// 2026-10-21 凌晨他让人装 ComfyUI，就为一件事：「我想让她能自己画画」。
// 装的那套在 D:\ComfyUI（tools/comfyui-install.mjs 负责装、解压、下模型、起服务），
// 这个模块只负责**画**：给它一句话，回来一张图。
//
// 为什么要单开一个模块，而不是让调用方各自抄一份 graph：
//   · 桌面面板（desk/bridge.mjs）要用，心跳（heartbeat/heartbeat.mjs）以后也要用；
//   · graph 抄错的代价很具体 —— FLUX.1-schnell 是 distilled，只能 4 步、cfg 1.0、euler+simple、
//     negative 留空；照 SDXL 的 28 步去写，出来的是一团糊的东西，而且不报错。
//
// 用法：
//   import { draw, isUp } from './comfy.mjs';
//   const r = await draw({ prompt: 'a small orange fish, dark water, rim light' });
//   if (!r.ok) ...; else r.file / r.seconds
//
// 选型（2026-10-21 实测，16 GB 显存 / Blackwell）：
//   flux  FLUX.1-schnell fp8 · 16.05 GB 权重 · 4 步 · 1024 一张约 14 秒（首次含加载 21 秒）
//   sdxl  SDXL base 1.0 · 6.46 GB · 28 步 · 快，当基准 / 当兜底
import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const WORKSPACE = path.resolve(HERE, '..', '..');

export const COMFY_ROOT = process.env.COMFY_ROOT || 'D:\\ComfyUI';
export const COMFY_APP = path.join(COMFY_ROOT, 'app');
export const COMFY_OUT = path.join(COMFY_ROOT, 'output');
export const COMFY_PORT = Number(process.env.COMFY_PORT || 8188);
const BASE = 'http://127.0.0.1:' + COMFY_PORT;

for (const d of [COMFY_ROOT, COMFY_OUT]) { try { fs.mkdirSync(d, { recursive: true }); } catch { } }

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** 服务在不在。ComfyUI 没起来的时候 fetch 会几秒才失败，所以给个短超时。 */
export async function isUp() {
  try {
    const r = await fetch(BASE + '/system_stats', { signal: AbortSignal.timeout(3000) });
    return r.ok;
  } catch { return false; }
}

/** 不在就把它叫起来（起过一次就一直常驻，一般不会走到这儿）。 */
async function ensureUp(waitSec = 120) {
  if (await isUp()) return true;
  const installer = path.join(WORKSPACE, 'dafeiyu', 'tools', 'comfyui-install.mjs');
  try {
    const p = spawn(process.execPath, [installer, '--start'], { detached: true, stdio: 'ignore', windowsHide: true });
    p.unref();
  } catch { }
  const t0 = Date.now();
  while (Date.now() - t0 < waitSec * 1000) {
    await sleep(2000);
    if (await isUp()) return true;
  }
  return false;
}

/** 两个模型的 graph。seed 每次都换 —— 固定 seed 会让同一句话永远出同一张图。 */
function graphFor(model, { prompt, width, height, seed }) {
  if (model === 'sdxl') {
    return {
      '4': { class_type: 'CheckpointLoaderSimple', inputs: { ckpt_name: 'sd_xl_base_1.0.safetensors' } },
      '5': { class_type: 'EmptyLatentImage', inputs: { width, height, batch_size: 1 } },
      '6': { class_type: 'CLIPTextEncode', inputs: { text: prompt, clip: ['4', 1] } },
      '7': { class_type: 'CLIPTextEncode', inputs: { text: 'blurry, low quality, watermark, text', clip: ['4', 1] } },
      '3': {
        class_type: 'KSampler', inputs: {
          seed, steps: 28, cfg: 7.0, sampler_name: 'dpmpp_2m', scheduler: 'karras', denoise: 1.0,
          model: ['4', 0], positive: ['6', 0], negative: ['7', 0], latent_image: ['5', 0],
        },
      },
      '8': { class_type: 'VAEDecode', inputs: { samples: ['3', 0], vae: ['4', 2] } },
      '9': { class_type: 'SaveImage', inputs: { filename_prefix: 'dfy-sdxl', images: ['8', 0] } },
    };
  }
  // FLUX.1-schnell：4 步、cfg 1.0、euler+simple、negative 留空（它是 distilled，不是 dev）
  return {
    '1': { class_type: 'UNETLoader', inputs: { unet_name: 'flux1-schnell-fp8.safetensors', weight_dtype: 'default' } },
    '2': { class_type: 'DualCLIPLoader', inputs: { clip_name1: 't5xxl_fp8_e4m3fn.safetensors', clip_name2: 'clip_l.safetensors', type: 'flux' } },
    '3': { class_type: 'VAELoader', inputs: { vae_name: 'ae.safetensors' } },
    '4': { class_type: 'CLIPTextEncode', inputs: { text: prompt, clip: ['2', 0] } },
    '5': { class_type: 'CLIPTextEncode', inputs: { text: '', clip: ['2', 0] } },
    '6': { class_type: 'EmptyLatentImage', inputs: { width, height, batch_size: 1 } },
    '7': {
      class_type: 'KSampler', inputs: {
        seed, steps: 4, cfg: 1.0, sampler_name: 'euler', scheduler: 'simple', denoise: 1.0,
        model: ['1', 0], positive: ['4', 0], negative: ['5', 0], latent_image: ['6', 0],
      },
    },
    '8': { class_type: 'VAEDecode', inputs: { samples: ['7', 0], vae: ['3', 0] } },
    '9': { class_type: 'SaveImage', inputs: { filename_prefix: 'dfy-flux', images: ['8', 0] } },
  };
}

/**
 * 画一张。
 * @param {{prompt:string, model?:'flux'|'sdxl', width?:number, height?:number, seed?:number, timeoutSec?:number}} o
 * @returns {Promise<{ok:boolean, file?:string, seconds?:number, model?:string, seed?:number, error?:string}>}
 */
export async function draw(o = {}) {
  const prompt = String(o.prompt || '').trim();
  if (!prompt) return { ok: false, error: '要画什么是空的' };
  const model = o.model === 'sdxl' ? 'sdxl' : 'flux';
  // 1024 是这两个模型的原生尺寸；再大 16 GB 显存会 offload 得很惨。
  const clamp = (n, lo, hi) => Math.min(Math.max(Math.round(Number(n) || 1024), lo), hi);
  const width = clamp(o.width, 512, 1536);
  const height = clamp(o.height, 512, 1536);
  const seed = Number.isInteger(o.seed) ? o.seed : Math.floor(Math.random() * 1e15);
  const budget = Math.min(Math.max(Number(o.timeoutSec) || 240, 30), 600) * 1000;

  if (!(await ensureUp(120))) return { ok: false, error: 'ComfyUI 没起来（' + COMFY_PORT + ' 没响应）' };

  const t0 = Date.now();
  let jid;
  try {
    const r = await fetch(BASE + '/prompt', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ prompt: graphFor(model, { prompt, width, height, seed }), client_id: 'dafeiyu' }),
      signal: AbortSignal.timeout(15000),
    });
    const j = await r.json().catch(() => ({}));
    jid = j.prompt_id;
    if (!jid) {
      // 最常见的一种：模型名 / 前端不认的节点。原文带回来，别吞掉。
      const why = j?.error?.message || (j?.node_errors ? JSON.stringify(j.node_errors).slice(0, 300) : JSON.stringify(j).slice(0, 300));
      return { ok: false, error: '被 ComfyUI 拒了：' + why };
    }
  } catch (e) {
    return { ok: false, error: '连不上 ComfyUI：' + (e?.message || String(e)) };
  }

  while (Date.now() - t0 < budget) {
    await sleep(1200);
    let rec = null;
    try {
      const h = await fetch(BASE + '/history/' + jid, { signal: AbortSignal.timeout(8000) }).then((x) => x.json());
      rec = h[jid];
    } catch { continue; }
    if (!rec) continue;
    if (rec.status && rec.status.status_str === 'error') {
      return { ok: false, error: '画到一半出错：' + JSON.stringify(rec.status).slice(0, 300) };
    }
    const imgs = rec.outputs && rec.outputs['9'] && rec.outputs['9'].images;
    if (imgs && imgs.length) {
      const img = imgs[0];
      const src = path.join(COMFY_APP, 'ComfyUI', 'output', img.subfolder || '', img.filename);
      const dst = path.join(COMFY_OUT, img.filename);
      let file = src;
      try {
        if (path.resolve(src) !== path.resolve(dst)) fs.copyFileSync(src, dst);
        file = dst;
      } catch { }
      return { ok: true, file, seconds: Math.round((Date.now() - t0) / 10) / 100, model, seed };
    }
  }
  return { ok: false, error: '等了 ' + Math.round(budget / 1000) + ' 秒还没出图（工单 ' + jid + '）' };
}
