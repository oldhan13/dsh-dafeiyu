"""ASR 引擎：把 faster-whisper 包成「加载一次、反复用」的一小块。

为什么单独成文件：`ctranslate2` 的 wheel **不自带 CUDA 运行库**（cuBLAS / cuDNN 要从
`nvidia-*-cu12` 这些 wheel 里来），而它们的 DLL 躺在 `site-packages/nvidia/*/bin`，
不在 PATH 上 —— 不手动 `os.add_dll_directory` 就会报
`Library cublas64_12.dll is not found or cannot be loaded`。
这段注册必须在 `import ctranslate2` 之前做完，所以单独抽出来。

另一个坑：`language="zh"` 经常吐**繁体**。`initial_prompt` 能把解码往简体拽，
但拽不干净的时候再用 `zhconv` 兜一层（装了就用，没装就原样返回）。

用法：
    from asr import AsrEngine
    eng = AsrEngine()               # 默认 cuda/float16，不行就退 cpu/int8
    text = eng.transcribe(audio)    # audio: float32 mono @16k, [-1,1]
    print(text, eng.last_ms)
"""
from __future__ import annotations

import glob
import os
import site
import sys
import time

for _s in (sys.stdout, sys.stderr):
    try:
        _s.reconfigure(encoding="utf-8", errors="replace")
    except Exception:  # noqa: BLE001
        pass


def register_cuda_dlls() -> list[str]:
    """把 nvidia-*-cu12 wheel 里的 bin 目录加进 DLL 搜索路径。返回加进去的目录。

    ⚠️ 两个坑，都踩过：
    ① `site.getsitepackages()[0]` 是**安装前缀**（…\\Python312），**不是** site-packages；
       真正的库在 [1]。所以这里把列表里每个根都试一遍，别只取 [0]。
    ② 只调 `os.add_dll_directory` **不够** —— ctranslate2 是用普通 `LoadLibrary("cublas64_12.dll")`
       找库的，那条路走的是 **PATH**，不走 AddDllDirectory 的列表。
       两个都要做，缺一个就还是 `Library cublas64_12.dll is not found or cannot be loaded`。
    """
    added: list[str] = []
    roots = []
    try:
        roots.extend(site.getsitepackages())
    except Exception:  # noqa: BLE001
        pass
    try:
        roots.append(site.getusersitepackages())
    except Exception:  # noqa: BLE001
        pass
    roots.append(os.path.join(os.path.dirname(sys.executable), "Lib", "site-packages"))

    seen = set()
    for root in roots:
        if not root or root in seen:
            continue
        seen.add(root)
        pattern = os.path.join(root, "nvidia", "*", "bin")
        for d in sorted(glob.glob(pattern)):
            if not os.path.isdir(d) or d.lower() in {a.lower() for a in added}:
                continue
            try:
                os.add_dll_directory(d)
            except Exception:  # noqa: BLE001
                pass
            added.append(d)

    if added:
        os.environ["PATH"] = ";".join(added) + ";" + os.environ.get("PATH", "")
    return added


_CUDA_DIRS = register_cuda_dlls()

DEFAULT_PROMPT = "以下是普通话的句子，用简体中文书写。"

try:
    from zhconv import convert as _zh_convert
except Exception:  # noqa: BLE001
    _zh_convert = None

# 繁体里高频、且 whisper 常吐的那几个字，没装 zhconv 时兜底
_T2S_FALLBACK = str.maketrans({
    "這": "这", "個": "个", "說": "说", "聽": "听", "見": "见", "嗎": "吗", "話": "话",
    "點": "点", "醫": "医", "院": "院", "覺": "觉", "辦": "办", "換": "换", "麼": "么",
    "對": "对", "開": "开", "關": "关", "沒": "没", "會": "会", "時": "时", "間": "间",
    "問": "问", "題": "题", "東": "东", "西": "西", "買": "买", "賣": "卖", "錢": "钱",
    "們": "们", "還": "还", "過": "过", "給": "给", "讓": "让", "從": "从", "來": "来",
    "為": "为", "應": "应", "該": "该", "樣": "样", "種": "种", "實": "实", "現": "现",
    "體": "体", "裡": "里", "邊": "边", "頭": "头", "臉": "脸", "說": "说", "誰": "谁",
})


def to_simplified(text: str) -> str:
    if not text:
        return text
    if _zh_convert is not None:
        try:
            return _zh_convert(text, "zh-cn")
        except Exception:  # noqa: BLE001
            pass
    return text.translate(_T2S_FALLBACK)


class AsrEngine:
    def __init__(self, model: str = "small", device: str | None = None,
                 compute: str | None = None, prompt: str = DEFAULT_PROMPT):
        from faster_whisper import WhisperModel  # 必须在 register_cuda_dlls 之后

        self.prompt = prompt
        self.last_ms = 0.0
        self.model_name = model
        self.device = device
        self.compute = compute
        self._explain = ""

        attempts = []
        if device is None:
            attempts = [("cuda", "float16"), ("cpu", "int8")]
        else:
            attempts = [(device, compute or ("float16" if device == "cuda" else "int8"))]

        last_err = None
        for dev, cmp in attempts:
            try:
                t0 = time.time()
                self._build(dev, cmp)
                self.load_s = time.time() - t0
                self._explain = f"{dev}/{cmp} 加载+warmup {self.load_s:.2f}s"
                return
            except Exception as e:  # noqa: BLE001
                last_err = f"{dev}/{cmp}: {type(e).__name__}: {e}"
        raise RuntimeError(f"ASR 模型一个都没跑通（最后错误 {last_err}）")

    def _build(self, device: str, compute: str):
        """加载 + 探测。两条都成功才算这条设备可用。"""
        from faster_whisper import WhisperModel

        m = WhisperModel(self.model_name, device=device, compute_type=compute)
        # ⚠️ ctranslate2 的 CUDA 缺库**不会在构造时报错** —— 它加载成功，
        # 等到第一次 encode 才抛 `Library cublas64_12.dll is not found`。
        # 所以必须在这里真跑一遍，才能判断这条路能不能用。
        self._probe(m)
        self._model = m
        self.device, self.compute = device, compute

    @staticmethod
    def _probe(m):
        """跑 0.6 秒低幅噪声。

        ⚠️ **不能用纯静音**：实测 0.4 秒全零能「跑通」——它压根没走到真正要 cuBLAS 的那步，
        于是缺库的时候 probe 会假阳性通过，等真语音一来才炸 `Library cublas64_12.dll is not found`。
        噪声才逼得它做真正的矩阵乘。第一遍慢（CUDA 上下文 + cuDNN 算法选择），顺便当 warmup。
        """
        import numpy as np
        rng = np.random.default_rng(0)
        noise = (rng.standard_normal(int(0.6 * 16000)) * 0.05).astype("float32")
        for _ in m.transcribe(noise, language="zh", beam_size=1, vad_filter=False):
            pass

    def warmup(self):
        try:
            self._probe(self._model)
        except Exception:  # noqa: BLE001
            pass

    def transcribe(self, audio, vad: bool = False, beam_size: int = 1) -> str:
        """audio: float32 mono @16000, [-1,1]。返回简体中文文本。

        万一 CUDA 这条在真语音上炸（比如缺 cuBLAS 的 DLL —— 短探测会假阳性通过），
        **当场降到 CPU 把这一句补上**，不让整通电话断掉。
        """
        try:
            return self._transcribe_once(audio, vad, beam_size)
        except Exception as e:  # noqa: BLE001
            if self.device != "cuda":
                raise
            msg = str(e)
            self._explain = f"{self.device}/{self.compute} 失败（{msg[:80]}），已降到 CPU"
            try:
                self._build("cpu", "int8")
                self._probe(self._model)
                return self._transcribe_once(audio, vad, beam_size)
            except Exception:
                raise e

    def _transcribe_once(self, audio, vad: bool, beam_size: int) -> str:
        t0 = time.time()
        segments, _info = self._model.transcribe(
            audio,
            language="zh",
            beam_size=beam_size,
            vad_filter=vad,
            initial_prompt=self.prompt,
            condition_on_previous_text=False,
        )
        raw = "".join(s.text for s in segments).strip()
        self.last_ms = (time.time() - t0) * 1000.0
        return to_simplified(raw)

    def describe(self) -> str:
        return self._explain


if __name__ == "__main__":
    print("nvidia dll dirs:", _CUDA_DIRS or "(没有)")
    print("zhconv:", "有" if _zh_convert else "没有（用内置兜底表）")
    eng = AsrEngine()
    print(eng.describe())
