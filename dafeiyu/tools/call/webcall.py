# -*- coding: utf-8 -*-
"""网页通话：手机/电脑浏览器连进来，跟汐实时对讲。

为什么不是「发语音消息」：这里是一条**双工**链路 ——
    浏览器麦克风 → 16k PCM16 → WebSocket → VAD → GPU 转写 → DeepSeek → piper → 回传 → 浏览器播放
她说话的时候你随时能插话（引擎那边的 barge-in 会立刻掐掉她那句）。

三个必须知道的点：

1. ★ **必须 https**。浏览器只在「安全上下文」（https 或 localhost）里给麦克风权限，
   手机连 `http://192.168.x.x:8443` 是拿不到麦的。所以这里自签一张证书，
   手机上会弹一次「不受信任」，点「高级 → 继续前往」就行。
2. ★ **网速不是瓶颈，延迟在「转写 + 想 + 首块 TTS」**。实测（本机，cuda/float16 small）：
   2.1s 的话转写 0.6s、DeepSeek 0.7s、piper 首块 0.15s ⇒ 开口约 1.5s。
3. ★ **她的话按真实时长往外送**（PacedSink），不是一次全灌给浏览器 ——
   否则 barge-in 只剩 TTS 那 0.4 秒窗口，等于没有。

用法：
    python webcall.py                 # 8443，自签证书
    python webcall.py --port 9443 --no-tls   # 只有 localhost 能用（手机不行）
"""
from __future__ import annotations

import asyncio
import datetime
import ipaddress
import json
import os
import socket
import ssl
import sys
import time

for _s in (sys.stdout, sys.stderr):
    try:
        _s.reconfigure(encoding="utf-8", errors="replace")
    except Exception:  # noqa: BLE001
        pass

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import numpy as np
import websockets
from websockets.asyncio.server import serve
from websockets.datastructures import Headers
from websockets.http11 import Response

from engine import CallEngine, log
import config as cfgmod

PAGE = os.path.join(HERE, "webcall.html")
STATE_DIR = os.path.normpath(os.path.join(HERE, "..", "..", "state", "call"))
CERT = os.path.join(STATE_DIR, "webcall-cert.pem")
KEY = os.path.join(STATE_DIR, "webcall-key.pem")


# ---------------------------------------------------------------- 证书

def lan_ips() -> list[str]:
    ips = set()
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.settimeout(0.5)
        s.connect(("8.8.8.8", 80))
        ips.add(s.getsockname()[0])
        s.close()
    except Exception:  # noqa: BLE001
        pass
    try:
        for ip in socket.gethostbyname_ex(socket.gethostname())[2]:
            ips.add(ip)
    except Exception:  # noqa: BLE001
        pass
    return sorted(i for i in ips if not i.startswith("169.254."))


def ensure_cert() -> None:
    """自签证书。已存在就直接用（重生会让手机再点一次「继续前往」）。"""
    os.makedirs(STATE_DIR, exist_ok=True)
    if os.path.exists(CERT) and os.path.exists(KEY):
        age = time.time() - os.path.getmtime(CERT)
        if age < 300 * 86400:
            return
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import rsa
    from cryptography.x509.oid import NameOID

    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "xibu-webcall")])
    sans = [x509.DNSName("localhost")] + [x509.IPAddress(ipaddress.ip_address(i))
                                          for i in ["127.0.0.1"] + lan_ips()]
    now = datetime.datetime.now(datetime.timezone.utc)
    cert = (x509.CertificateBuilder()
            .subject_name(name).issuer_name(name)
            .public_key(key.public_key())
            .serial_number(x509.random_serial_number())
            .not_valid_before(now - datetime.timedelta(days=1))
            .not_valid_after(now + datetime.timedelta(days=360))
            .add_extension(x509.SubjectAlternativeName(sans), critical=False)
            .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
            .sign(key, hashes.SHA256()))
    with open(KEY, "wb") as f:
        f.write(key.private_bytes(serialization.Encoding.PEM,
                                  serialization.PrivateFormat.TraditionalOpenSSL,
                                  serialization.NoEncryption()))
    with open(CERT, "wb") as f:
        f.write(cert.public_bytes(serialization.Encoding.PEM))
    log(f"[证书] 生成自签证书 → {CERT}（覆盖 {', '.join(['127.0.0.1'] + lan_ips())}）")


# ---------------------------------------------------------------- 出口：按真实时长往外送

class PacedSink:
    """把她的音频切成 ~100ms 的小片，按**真实播放时长**往外送。

    为什么不能一次灌完：barge-in 是在 `for ch in it` 里逐块检查的 ——
    一次全送完，等于她「0.4 秒就说完了整句」，打断窗口就没了。
    """

    def __init__(self, send, slice_s: float = 0.10, lead: float = 0.12):
        self.send = send
        self.slice_s = slice_s
        self.lead = lead
        self._t0 = None
        self._played = 0.0

    def reset(self) -> None:
        self._t0 = time.monotonic()
        self._played = 0.0

    def __call__(self, chunk, rate: int) -> None:
        a = np.asarray(chunk, dtype="float32").ravel()
        if not len(a):
            return
        if self._t0 is None:
            self.reset()
        step = max(1, int(rate * self.slice_s))
        for i in range(0, len(a), step):
            self.send(a[i:i + step], rate)
            self._played += len(a[i:i + step]) / rate
            behind = self._played - (time.monotonic() - self._t0)
            if behind > self.lead:
                time.sleep(max(0.0, min(behind - self.lead, self.slice_s * 1.5)))


# ---------------------------------------------------------------- 一个通话会话

class Session:
    def __init__(self, ws, asr, piper, web):
        self.ws = ws
        self.web = web
        self.loop = asyncio.get_running_loop()
        self.out: asyncio.Queue = asyncio.Queue()
        self.paced = PacedSink(self._send_audio)
        self.engine: CallEngine | None = None
        self.asr = asr
        self.piper = piper
        self.frames = 0
        self.started = time.time()

    # ---- 出站
    def _send_audio(self, chunk, rate: int) -> None:
        b = (np.clip(np.asarray(chunk, dtype="float32"), -1, 1) * 32767).astype("<i2").tobytes()
        try:
            self.loop.call_soon_threadsafe(self.out.put_nowait, ("a", b))
        except RuntimeError:
            pass

    def _send_json(self, obj) -> None:
        try:
            self.loop.call_soon_threadsafe(self.out.put_nowait, ("j", obj))
        except RuntimeError:
            pass

    def _on_event(self, e: dict) -> None:
        if e.get("t") == "say_start":
            self.paced.reset()
        self._send_json(e)

    async def writer(self) -> None:
        while True:
            kind, payload = await self.out.get()
            if kind == "j":
                await self.ws.send(json.dumps(payload, ensure_ascii=False))
            else:
                await self.ws.send(payload)

    # ---- 主流程
    async def run(self) -> None:
        self.engine = CallEngine(asr=self.asr, tts_backend=self.web.tts_backend,
                                 tts_engine=self.piper, sink=self.paced,
                                 on_event=self._on_event, verbose=True)
        self.engine.start()
        w = asyncio.create_task(self.writer())
        log(f"[会话] 接通 {self.ws.remote_address}")
        try:
            async for msg in self.ws:
                if isinstance(msg, (bytes, bytearray)):
                    self.frames += 1
                    self.engine.feed(np.frombuffer(bytes(msg), dtype="<i2"))
                else:
                    try:
                        j = json.loads(msg)
                    except Exception:  # noqa: BLE001
                        continue
                    if j.get("t") == "hi":
                        log(f"[会话] 浏览器上行采样率 {j.get('rate')}")
        except websockets.ConnectionClosed:
            pass
        finally:
            w.cancel()
            self.engine.stop()
            log(f"[会话] 挂断，{time.time()-self.started:.0f}s，"
                f"{len(self.engine.turns)} 轮，收到 {self.frames} 包")
            for t in self.engine.turns:
                log(f"    {t}")


# ---------------------------------------------------------------- 服务器

def make_process_request(page: bytes, stop=None):
    def process_request(connection, request):
        path = (request.path or "/").split("?")[0]
        if path.startswith("/ws"):
            return None                      # 交给 websocket 握手
        if path in ("/", "/index.html", "/webcall.html"):
            return Response(200, "OK", Headers({
                "Content-Type": "text/html; charset=utf-8",
                "Content-Length": str(len(page)),
                "Cache-Control": "no-store",
                "Connection": "close",
            }), page)
        if path == "/health":
            body = b'{"ok":true}'
            return Response(200, "OK", Headers({
                "Content-Type": "application/json",
                "Content-Length": str(len(body)),
                "Connection": "close",
            }), body)
        if path == "/quit":
            # 让位通道：res.py 要顶掉这一通时走这里（礼貌优先，硬杀是兜底）
            if stop is not None:
                stop.set()
            body = b'{"ok":true,"bye":true}'
            return Response(200, "OK", Headers({
                "Content-Type": "application/json",
                "Content-Length": str(len(body)),
                "Connection": "close",
            }), body)
        body = b"not found"
        return Response(404, "Not Found", Headers({
            "Content-Type": "text/plain; charset=utf-8",
            "Content-Length": str(len(body)),
            "Connection": "close",
        }), body)
    return process_request


class WebCall:
    def __init__(self, asr, piper, tts_backend: str, idle_exit: float = 600.0):
        self.asr = asr
        self.piper = piper
        self.tts_backend = tts_backend
        self.sessions = 0
        self.idle_exit = idle_exit
        self.last_active = time.time()

    async def handler(self, ws) -> None:
        self.sessions += 1
        self.last_active = time.time()
        try:
            await Session(ws, self.asr, self.piper, self).run()
        finally:
            self.sessions -= 1
            self.last_active = time.time()

    async def idle_keeper(self, stop) -> None:
        """★ 没人打就自己退 —— 它不该是一个需要人记得去关的东西。

        注意：判据是「**没有会话**且**一段时间没人连**」，不是「没有请求」——
        页面开着但没拨号也算空闲，那正是该收摊的时候。
        """
        if not self.idle_exit:
            return
        while True:
            await asyncio.sleep(20)
            if self.sessions <= 0 and (time.time() - self.last_active) > self.idle_exit:
                log(f"[空闲] {self.idle_exit:.0f} 秒没人打，自己退（端口和显存让出来）")
                stop.set()
                return


async def amain(args) -> int:
    ensure_cert()
    with open(PAGE, "rb") as f:
        page = f.read()

    stop = asyncio.Event()

    # ★ 通话位：同一时刻只该有一通电话。网页这边拨进来，桌宠那边那一通让位。
    try:
        import res
        # ★ 登记**完整地址**：这里是 https（自签证书），让位通道要按这个协议去打，
        #   不然 res 那边拼 http 会握手失败，最后变成硬杀。
        _scheme = "http" if args.no_tls else "https"
        taken = res.claim("webcall", "web", port=args.port,
                          url=f"{_scheme}://127.0.0.1:{args.port}/quit")
        if taken:
            log(f"[接管] 原来那一通（{taken.get('who')} pid {taken.get('pid')}）已让位")
    except Exception as e:  # noqa: BLE001
        log(f"[资源] 通话位没登记上（不影响这一通）：{type(e).__name__}: {e}")

    # ---- 预热：耳朵与 piper 都只加载一次，所有会话共用
    t0 = time.time()
    from asr import make_asr
    log("[ASR] 要耳朵（常驻服务优先）…")
    asr = make_asr(model=args.model, device=args.asr_device)
    log(f"[ASR] {asr.describe()}")

    piper = None
    backend = args.tts or cfgmod.backend()
    if backend == "piper":
        import tts as ttsmod
        log("[TTS] 加载本地 piper …")
        piper = ttsmod.piper_from_config()
        log(f"[TTS] piper {piper.load_ms:.0f}ms · 预热 {piper.warmup_ms:.0f}ms · {piper.rate}Hz")
        log(f"[TTS] 语气 快慢 {piper.syn.length_scale} · 起伏 {piper.syn.noise_w_scale}")
    else:
        log(f"[TTS] 用 {backend}（{cfgmod.label_of(backend)}）")
    log(f"[就绪] 预热合计 {(time.time()-t0)*1000:.0f}ms")

    web = WebCall(asr, piper, backend, idle_exit=args.idle_exit)
    ctx = None
    if not args.no_tls:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(CERT, KEY)

    try:
        async with serve(web.handler, args.host, args.port, ssl=ctx, max_size=None,
                         process_request=make_process_request(page, stop)) as server:
            scheme = "http" if args.no_tls else "https"
            log("=" * 62)
            log(f"  网页通话已开：{scheme}://127.0.0.1:{args.port}/")
            if not args.no_tls:
                for ip in lan_ips():
                    log(f"                 {scheme}://{ip}:{args.port}/   ← 手机用这个")
                log("  ★ 自签证书：手机上会弹「不受信任」，点 高级 → 继续前往")
            else:
                log("  ★ 没有 TLS：只有本机 localhost 能拿到麦克风，手机不行")
            if args.idle_exit:
                log(f"  ★ 空闲 {args.idle_exit:.0f} 秒没人打会自动退出（不用人记得关）")
            log("=" * 62)
            keeper = asyncio.create_task(web.idle_keeper(stop))
            try:
                await stop.wait()
            finally:
                keeper.cancel()
    finally:
        try:
            import res
            res.release("webcall")
        except Exception:  # noqa: BLE001
            pass
    return 0


def main() -> int:
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=8443)
    ap.add_argument("--no-tls", action="store_true", help="只有本机可用（手机拿不到麦克风）")
    ap.add_argument("--tts", default=None, choices=["piper", "sovits", "cloud", "openai"],
                    help="不填就用 config.json 里选的")
    ap.add_argument("--model", default="small")
    ap.add_argument("--asr-device", default=None)
    ap.add_argument("--idle-exit", type=float, default=0.0,
                    help="多少秒没人打就自己退出（0 = 一直开着，默认）。"
                         "★ 它现在几乎不占东西：耳朵在常驻服务里、嘴在 sovits 里，"
                         "本进程只管转发 —— 所以不该按「省资源」的逻辑催它退")
    args = ap.parse_args()
    try:
        asyncio.run(amain(args))
    except KeyboardInterrupt:
        log("^C")
    return 0


if __name__ == "__main__":
    sys.exit(main())
