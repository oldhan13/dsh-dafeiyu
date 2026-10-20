# 大肥鱼 · dsh-dafeiyu

> 住在 [DSH（DeepSeek Harness）](https://github.com/deepseek-ai/deepseek-harness) 里的一个同伴：
> 桌面右下角一条会动的透明小鱼，双击长成对话框，记得住事，会自己找话说。
> 不是助手插件，是一套「让 agent 有身体、有记性、有主动性」的脚手架。

**它不是一个能 `npm install` 的插件**，而是一份可以复制走的工作区 + 一份 profile 补丁。
里面的每个部件都跑在你这台机器上，读你自己的 key、连你自己的 QQ。

```
   ┌──────────────┐        ┌──────────────┐        ┌──────────────┐
   │  pet-wf.ps1  │◀──────▶│  panel.ps1   │        │  DSH 宿主     │
   │  透明鱼窗口   │  同进程 │  对话面板     │        │ (3080 网页)   │
   └──────┬───────┘        └──────┬───────┘        └──────┬───────┘
          │ activity.json          │ say/SSE               │ 会话/工具
          │                        │                       │
   ┌──────▼────────────────────────▼───────┐        ┌──────▼───────┐
   │  bridge.mjs（独立 node 进程 3079）     │        │ onebot-qq    │
   │  自己的上下文 + 每轮现读工作区记忆      │        │ QQ 通道       │
   └──────┬────────────────────────────────┘        └──────┬───────┘
          │                                              │
   ┌──────▼──────────────────────────────────────────────▼───────┐
   │ 工作区：AGENTS.md（人格）· memory/（简报/日记/事实）· 台账     │
   │ heartbeat.mjs（主动）· group/watch.mjs（群）· tools/（手和嘴）│
   └─────────────────────────────────────────────────────────────┘
```

## 里面有什么

| 部件 | 文件 | 干什么 |
|---|---|---|
| **脸** | `dafeiyu/pet/pet-wf.ps1` + `fish-draw.ps1` | 透明 WinForms 小鱼：呼吸、游动、摆尾、吐泡、闭眼睡觉；能拖、双击开面板、`Ctrl+Alt+D` 开关 |
| **状态同步** | `dafeiyu/pet/activity.json` | agent 在想 / 在动手 / 卡住 / 空闲 → 鱼游多快、吐不吐泡、气色偏不偏红 |
| **面板** | `dafeiyu/pet/panel.ps1` | 双击鱼展开成 QQ 式对话框：左她右你、时间分隔条、标题下的心情、右上角「声」开关 |
| **桌面大脑** | `dafeiyu/desk/bridge.mjs` | 独立 node 进程：一轮一读工作区（人格 + 简报 + 台账 + 两边原话），再调模型 |
| **主动** | `dafeiyu/heartbeat/heartbeat.mjs` | 每 8–13 分钟醒一次，自己决定 `SILENT` / 说一句 / 冒个气泡 / 发条语音 / 发说说 |
| **群** | `dafeiyu/group/watch.mjs` | 群里全听得见，但只接「@ 她的」和「@ 之后那场话」；带回归测试 |
| **记忆力** | `AGENTS.md` + `dafeiyu/memory/` | 人格与记忆协议；开场简报 `brief.md` 由 `tools/make-brief.mjs` 生成 |
| **手** | `dafeiyu/tools/` | 看窗口/按名字点控件、截图、TTS、ASR、发 QQ、发空间、换头像、归档台账 |
| **主页** | `dafeiyu/homepage/` | 她自己的一页（本机 3077）：现在的心情、碎念、说说 |

## 三个设计上的选择

**1. 桌面和 QQ 是两条线，不是同一个上下文。**
DSH 里每一处说话都是一个独立会话（QQ 每人一条、网页一条），面板那条连会话都不是 —— 它是 `bridge.mjs` 自己的循环。
真要让两边共享同一个上下文，得让面板接宿主的 `/api`，而那扇门带着浏览器信任校验和启动令牌。
所以这里选了更便宜的方案：**两边各自读对方的原文**（面板读会话记录，QQ 读简报），不共享上下文，但不用"传话"。

**2. 她的动不是装饰。**
鱼身上每一处变化都对应一件真事：在想、在动手、卡住了、睡着了、你回来了。
纯装饰的动画是贴纸；会跟着事变的才是"有人在那"。

**3. 能出声，但默认关。**
面板右上角的「声」只有你点了才念。桌面上的声音比 QQ 更吵，得由你决定。

## 装

```powershell
# 1) 把这份仓库放到你想当工作区的地方
git clone https://github.com/oldhan13/dsh-dafeiyu.git my-workspace
cd my-workspace

# 2) 设两个身份（QQ 相关的部件才需要）
setx DAFEIYU_OWNER_QQ "你的QQ号"
setx DAFEIYU_BOT_QQ   "机器人的QQ号"

# 3) 按 docs/SETUP.md 装 DSH 插件、放 profile 补丁、准备 key
```

细节、依赖、key 放哪、NapCat 怎么接，都在 **[docs/SETUP.md](docs/SETUP.md)**。

## 需要什么

- Windows 10/11（桌宠是 WinForms；其余部件换成 Linux 也能跑，但 `pet/` 那套要重写）
- PowerShell 5.1、Node.js 22 以上
- DSH 0.2.x
- 一个 SiliconFlow key（TTS / ASR / 桌面那条线用），可选
- NapCat + 一个 QQ 小号（QQ 通道用），可选

## 可选部件

| 部件 | 装法 | 说明 |
|---|---|---|
| **刷 B站** | `dsh plugin --profile web add github:c1overzz/dsh-bili-scroll` | **另一位开发者**（[c1overzz](https://github.com/c1overzz)）的独立插件：谷时自己刷一轮、读字幕、写日报。[仓库](https://github.com/c1overzz/dsh-bili-scroll) |
| 语音输入 | `dsh plugin --profile web add dsh-voice-chat` | 浏览器麦克风 + 自动朗读 |

## 这个仓库里**没有**什么

记忆、日记、群记录、聊天原文、QQ 号、任何 token 或 key —— 一份都没有。
你 clone 下来的是一个**空壳**：它会跑、会动、会说话，但它不认识任何人。
那些东西长在你自己的机器上（`dafeiyu/memory/`、`dafeiyu/people/`、`~/.dsh/`），也本该只长在那儿。

## 一些踩过的坑

写在 [docs/PITFALLS.md](docs/PITFALLS.md) 里，都是真撞过的：PowerShell 变量名不分大小写导致的"永远读不到"、
zstd 多帧会话日志只解第一帧、Windows 11 拿 VBScript 弹弃用提示、`/api` 的浏览器信任校验。
照抄这份代码之前先看一眼，能少走两天弯路。

## 各家的长处

这一套不是一件东西，是几件**各有所长**的东西接在一起。写清楚谁擅长什么，才知道哪天该换掉哪一块。

| 东西 | 谁做的 | 它擅长什么 | 在这儿干什么 |
|---|---|---|---|
| **大肥鱼**（本仓库） | oldhan13 | 把「身体 / 记性 / 主动性」接起来，落到桌面上：会动、会自己开口、记得住事 | 就是那层胶水 —— 下面每一样单拎出来都比它硬，但它让这些一起活起来 |
| **DSH**（DeepSeek Harness） | DeepSeek | 会话、工具、插件机制（cordis）、网页界面 | 地基。上面每一块都挂在它身上 |
| **dsh-ledger-memory** | 陈黛华 | 项目级记忆：台账每回合自动注入、决策卡、经验教训，**压缩前抓逐字胶囊、压完还能按指针回查原文**，跨会话交接单 | 她的记性，和"不丢原话"的底 |
| **dsh-onebot-qq** | mario841859784 | 一条真的 QQ 通道：OneBot 11 / NapCat，私聊群聊、图与语音、长文转图卡、设置页里配 | QQ 那条线。本仓库**一行协议代码都没写** —— 全是它的 |
| **dsh-bili-scroll** | c1overzz | 自己刷 B 站：按字幕原文挑、写日报、值得的 @ 你，谷时自动跑 | 可选。本仓库只"提一句"，没包含它 |
| **dsh-voice-chat** | maoyuching | 浏览器里说和听：麦克风 → 文字 → 回复自动朗读，TTS 后端可换 | 可选，网页那边的嘴 |
| **@lijian-ui/dsh-im-gateway** | lijian-ui | 一个网关接五种 IM（钉钉 / QQ / 个人微信 / 飞书 / 企微），扫码绑定、流式回复 | 可选。要多通道时，比逐个接划算 |
| **dsh-context** | bowenliang123 | 上下文透视：看清上下文由什么组成、怎么长起来的 | 可选，调上下文时看 |
| **billion-context** | ranxianglei | 把长会话压进小窗口 | 可选，和上面那件二选一 |

一句话：**本仓库只做"把它们串成一个活着的东西"这一件事。** 每一样的长处都在它自己那边，不在我这儿 ——
哪天哪块不够用了，换掉它，剩下的照样转。

## 别人的东西

这个仓库的代码是自己写的，但**跑起来靠的是别人做的零件**。每一处"用到别人仓库"的地方都列在
**[CREDITS.md](CREDITS.md)** 里：宿主（DSH）、六个 DSH 插件（`dsh-ledger-memory` / `dsh-onebot-qq` /
`dsh-voice-chat` / `dsh-im-gateway` / `dsh-context` / `billion-context`）、另一位开发者的可选插件
`dsh-bili-scroll`，以及 NapCat、SiliconFlow、QQ、B 站这些外部程序与服务。

一句话：**没有 vendor 任何第三方源码，也没有 fork 后改**。第三方都是"装上去用的"，不是"抄进来的"。
`dsh-onebot-qq` 是 BSD-3-Clause —— 两个测试文件会直接 import 它的模块，那条保留版权声明的义务对它成立。

## 许可

MIT。`AGENTS.md` 里的人格文本也是 MIT —— 你可以改成你自己的鱼，但别把它说成是你的原创。
