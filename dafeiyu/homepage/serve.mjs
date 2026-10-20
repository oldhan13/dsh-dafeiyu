// 大肥鱼的主页 —— 零依赖静态服务器
// 用法：node serve.mjs [port]    默认 3077，只绑 127.0.0.1
// 她用自己的 write/edit 工具改 index.html 和 data/*.json，刷新页面就能看见。

import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.dirname(fileURLToPath(import.meta.url));
const PORT = Number(process.argv[2] || process.env.HOMEPAGE_PORT || 3077);
const HOST = '127.0.0.1';

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.webp': 'image/webp',
  '.mp3': 'audio/mpeg',
  '.woff2': 'font/woff2',
  '.txt': 'text/plain; charset=utf-8',
  '.md': 'text/plain; charset=utf-8'
};

const server = http.createServer((req, res) => {
  try {
    if (req.method !== 'GET' && req.method !== 'HEAD') {
      res.writeHead(405, { 'Content-Type': 'text/plain; charset=utf-8' });
      res.end('method not allowed');
      return;
    }
    const url = new URL(req.url, 'http://127.0.0.1');
    let rel = decodeURIComponent(url.pathname);
    if (rel.endsWith('/')) rel += 'index.html';
    // 目录穿越防护：解析后必须还在 ROOT 里
    const abs = path.resolve(ROOT, '.' + rel);
    if (abs !== ROOT && !abs.startsWith(ROOT + path.sep)) {
      res.writeHead(403, { 'Content-Type': 'text/plain; charset=utf-8' });
      res.end('forbidden');
      return;
    }
    let stat;
    try {
      stat = fs.statSync(abs);
    } catch {
      res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
      res.end('not found: ' + rel);
      return;
    }
    if (stat.isDirectory()) {
      res.writeHead(302, { Location: rel.replace(/\/?$/, '/') + '' });
      res.end();
      return;
    }
    const type = MIME[path.extname(abs).toLowerCase()] ?? 'application/octet-stream';
    res.writeHead(200, {
      'Content-Type': type,
      'Content-Length': stat.size,
      'Cache-Control': 'no-store'
    });
    if (req.method === 'HEAD') { res.end(); return; }
    fs.createReadStream(abs).pipe(res);
  } catch (error) {
    res.writeHead(500, { 'Content-Type': 'text/plain; charset=utf-8' });
    res.end('server error: ' + String(error));
  }
});

server.listen(PORT, HOST, () => {
  console.log(`[homepage] http://${HOST}:${PORT}/  root=${ROOT}`);
});
