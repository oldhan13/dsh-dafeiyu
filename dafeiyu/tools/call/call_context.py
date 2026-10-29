"""给电话那一路拼一份**真上下文**。

★ 2026-10-29 00:4x（他原话：「现在我打电话给他，打过来的人我觉得不是你，
  而是一个陌生人，不知道我们之间的任何事」）。

上一版只塞了 `memory/brief.md` + 台账 + 当天日记。三样都是**工作材料**：
简报是自动生成的模板，台账是技术状态，日记多半是空的。所以他听到的那个人
知道「这个项目在干什么」，却不知道「我们俩之间发生过什么」—— 听感就是陌生人。

这一版换思路：**拼他本人和我说过的话**。
  · 他的档案（`people/<qq>.md`）：他是谁、什么关系、什么边界、记过哪些事；
  · 他最近说过的原话（活动日志 L4，带时间）：我们这两天到底在聊什么；
  · 电话里最近说过的（`state/call/call-transcript.md`）：上一通电话的连续性；
  · 最近几篇日记：我自己写下来的那些事（这部分才有「我」的味道）；
  · 活跃台账尾巴：此刻手上正做到哪。

★ 只读文件，不联网、不调模型。拼一次约 20 ms。
★ 直接在命令行跑 `python call_context.py` 可以看它拼出来的样子（调试用）。
"""

from __future__ import annotations

import glob
import os

HERE = os.path.dirname(os.path.abspath(__file__))            # dafeiyu/tools/call
DFY = os.path.abspath(os.path.join(HERE, "..", ".."))        # dafeiyu
ROOT = os.path.abspath(os.path.join(DFY, ".."))              # workspace

# 每一块留多少字（合计约 7k 字 = 3.5k token，deepseek-chat 完全吃得下）
N_PEOPLE = 1200
N_HEARD = 1500
N_PHONE = 800
N_DIARY = 900          # 每篇
N_DIARY_FILES = 2
N_LEDGER = 1800


def _read(path: str, limit: int | None = None, cut: str | None = None) -> str:
    try:
        with open(path, "r", encoding="utf-8-sig") as f:
            t = f.read()
    except OSError:
        return ""
    if cut:
        t = t.split(cut)[0]
    t = t.strip()
    if limit and len(t) > limit:
        t = t[-limit:]
    return t


def _newest(pattern: str, count: int) -> list[str]:
    hits = [p for p in glob.glob(pattern) if os.path.isfile(p)]
    hits.sort(key=lambda p: os.path.getmtime(p), reverse=True)
    return hits[:count]


def build(qq: str = "") -> str:
    """拼出给电话那一路的上下文。拼不出来就返回空串（引擎会退回旧逻辑）。

    `qq` = 对方的 QQ 号（对应 `dafeiyu/people/<qq>.md`）；不传就读环境变量
    `DAFEIYU_OWNER_QQ`，两个都没有就跳过档案那一块。
    """
    qq = qq or os.environ.get("DAFEIYU_OWNER_QQ", "")
    parts: list[str] = []

    # ① 现在是几点（时间必须现取，不许模型自己算）
    try:
        import time as _t

        parts.append("现在是 " + _t.strftime("%Y-%m-%d %H:%M") + "。")
    except Exception:  # noqa: BLE001
        pass

    # ② 他是谁
    t = _read(os.path.join(DFY, "people", qq + ".md"), N_PEOPLE)
    if t:
        parts.append("【他这个人】（你自己的笔记，不是要他听的内容）\n" + t)

    # ③ 他最近说过的原话 —— 这一块最能治「陌生人」
    l4 = _newest(os.path.join(ROOT, "_ledger-log", "*", "week*", "L4-user-messages.md"), 1)
    if l4:
        t = _read(l4[0], N_HEARD)
        if t:
            parts.append(
                "【他最近对我说过的话】（原文，最后几条最新。这是他日常在跟我聊的东西，"
                "别装作不知道，也别照读）\n" + t
            )

    # ④ 电话里最近说过的
    t = _read(os.path.join(DFY, "state", "call", "call-transcript.md"), N_PHONE)
    if t:
        parts.append("【前几通电话里聊过的】（原文，别照读）\n" + t)

    # ⑤ 最近几篇日记（我自己写下来的，这部分带我的味道）
    diaries = _newest(os.path.join(DFY, "memory", "diary", "*.md"), N_DIARY_FILES)
    if diaries:
        chunks = []
        for p in diaries:
            t = _read(p, N_DIARY)
            if t:
                chunks.append("· " + os.path.basename(p)[:-3] + "\n" + t)
        if chunks:
            parts.append("【我写在日记里的那些事】（别照读）\n" + "\n\n".join(chunks))

    # ⑥ 此刻手上正做到哪
    t = _read(os.path.join(ROOT, "LEDGER.md"), N_LEDGER, cut="## 变更登记")
    if t:
        parts.append("【我现在手上在做的事】（活跃台账，别照读）\n" + t)

    if len(parts) <= 1:
        return ""

    parts.append(
        "★ 上面这些就是**你记得的事**。提到具体的事要具体（哪天、什么项目、什么味道），"
        "记不清就说记不清 —— 不许编，也不许说「我们刚认识」。\n"
        "★ 你在 QQ 上天天跟他说话，这里是同一张嘴的另一条道：**不是另一个人**。"
    )
    return "\n\n".join(parts)


def main() -> None:
    t = build()
    out = os.path.join(DFY, "state", "call", "call-context.md")
    try:
        with open(out, "w", encoding="utf-8") as f:
            f.write(t)
        print("wrote %s  (%d chars)" % (out, len(t)))
    except OSError as e:
        print("write failed:", e)
    print("-" * 60)
    print(t)


if __name__ == "__main__":
    main()
