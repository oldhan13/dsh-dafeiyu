# 别人的东西

这个仓库里的代码是自己写的，但**跑起来靠的是别人做的零件**。

这一页回答四件事：**谁做的、什么许可、它擅长什么、在本仓库里干什么**。
写"擅长什么"不是为了客气 —— 是让看的人知道哪一块该用谁的、哪天想换掉该换哪一块。
本仓库自己那一层放在 [第五节](#五本仓库自己这一层)，不跟这些放在一起比。

## 一、运行时依赖（别人的仓库 / npm 包）

全部是**安装后才用到**，这个仓库里**没有**它们的源码，一份都没有 vendor 进来。

| 包 | 谁做的 / 许可 | 它擅长什么 | 在本仓库里干什么 |
|---|---|---|---|
| [@deepseek-ai/dsh](https://github.com/deepseek-ai/deepseek-harness)（DeepSeek Harness） | DeepSeek / 见其仓库 | 会话、工具、插件机制（cordis）、网页界面 —— 一整套宿主 | 地基。上面每一块都挂在它身上 |
| [dsh-ledger-memory](https://github.com/18477514055/dsh-ledger-memory) | 陈黛华 / MIT | 项目级记忆：活跃台账每回合自动注入、决策卡、经验教训，**压缩前抓逐字胶囊、压完还能按指针回查原文**，跨会话交接单 | 她的记性。`AGENTS.md` §九—§十 和 `tools/ledger-*.mjs` 都是围着它写的 |
| [dsh-onebot-qq](https://github.com/mario841859784/dsh-onebot) | mario841859784 / **BSD-3-Clause** | 一条真的 QQ 通道：OneBot 11 / NapCat，私聊群聊、图与语音、长文转图卡、设置页里配 | QQ 那条线。本仓库**一行协议代码都没写**；`PITFALLS` 里那条中间消息的坑、`group/` 的判定都跟它有关 |
| [dsh-voice-chat](https://github.com/maoyuching/dsh-voice-chat) | maoyuching / MIT | 浏览器里说和听：麦克风 → 文字 → 回复自动朗读，TTS 后端可换（Edge TTS / MiMo / 自定义） | 可选：网页那边的嘴 |
| [@lijian-ui/dsh-im-gateway](https://github.com/lijian-ui/dsh-im-gateway) | lijian-ui / MIT | 一个网关接五种 IM（钉钉 / QQ / 个人微信 / 飞书 / 企微），扫码绑定、流式回复、统一入口 | 可选：要多通道时，比逐个接划算。本项目没深用 |
| [dsh-context](https://github.com/bowenliang123/dsh-context) | bowenliang123 / Apache-2.0 | 上下文透视：看清上下文由什么组成、怎么长起来的，带仪表盘和命令 | 可选：调上下文时看 |
| [billion-context](https://github.com/ranxianglei/billion-context) | ranxianglei / MIT | 把长会话压进小窗口：100K 上下文就够用，单个会话能开很久（月为单位） | 可选：和上面那件二选一 |

⚠️ `dafeiyu/tools/catchup.test.mjs` 和 `dafeiyu/tools/mention.test.mjs` 会在运行时**直接 import `dsh-onebot-qq` 包里的模块**
（不是复制它的代码）。要跑这两个测试，用 `DSH_ONEBOT_LIB` 指向那个包的 `lib` 目录。
它用的是 BSD-3-Clause：**保留版权声明**这一条对它同样成立。

## 二、另一位开发者的仓库（可选部件）

| 仓库 | 谁做的 / 许可 | 它擅长什么 | 关系 |
|---|---|---|---|
| [c1overzz/dsh-bili-scroll](https://github.com/c1overzz/dsh-bili-scroll) | c1overzz / MIT | 自己刷 B 站：按字幕原文挑、写日报、值得的 @ 你，谷时自动跑 | 本仓库**只是提到它**（`README` 的可选部件、`docs/SETUP.md` 与 `install.ps1` 各一句提示），没有包含、没有改它 |

> 关系写清楚：`c1overzz` 是**另一位开源开发者**，和本仓库作者（`oldhan13`）不是同一个人，
> 两边也没有从属或合作关系 —— 都是各自做各自的开源项目，碰巧这一套里有一件可选部件用得上他的。
> 装不装、用不用，看你自己。

## 三、外部程序与服务（不是代码依赖，但少了它们跑不起来）

| 东西 | 谁的 | 它擅长什么 | 要注意 |
|---|---|---|---|
| **NapCat** | 第三方 QQ 协议端 | 把 QQ 协议变成一条本地 HTTP / WebSocket 接口，插件才好接 | 自己的许可；要自己装、自己承担账号风险。本仓库只调它的接口 |
| **SiliconFlow** | 第三方模型服务 | 语音合成 / 转写，桌面那条线的对话也走它 | 要自己的 key，按它的条款计费 |
| **QQ** | 腾讯 | 消息、头像、界面 | 聊天内容、头像都是别人的东西，别拿来做训练语料或再分发 |
| **B 站** | 哔哩哔哩 | 标题、字幕、评论 | 字幕和评论的版权不在你手上，抓下来自己看可以，别转出去 |
| **维基文库** | Wikimedia | 公版文本 | 遵循它自己的协议 |

## 四、明确没做的

- 没有 vendor 任何第三方源码（`dsh-bili-scroll` 里的 `vendor/` 也不在本仓库）
- 没有 fork 别人的代码再改
- 没有把别人写的 prompt / 人格文本搬进来 —— `AGENTS.md` 是从零写的
- `fish-draw.ps1` 是几何画法（几段贝塞尔 + 正弦漂移），没有用任何 Live2D / 骨骼动画库

## 五、本仓库自己这一层

上面每一件单独拿出来都比这一层更硬 —— 这里没有协议、没有模型、没有新算法。本仓库长处在**接线和取舍**：

- **身体是连贯的**：鱼、面板、状态在同一个进程里；agent 在想 / 在动手 / 卡住 / 睡着，鱼身上看得出来。
  不是装饰动画 —— 每一处变化都对着一件真事。
- **主动性是自己判断的**：心跳每 8–13 分钟醒一次，可以什么都不说。没有定时问候、没有打卡。
- **记忆接到了日常**：一轮一读人格 + 简报 + 台账 + 两边原话，不靠"传话"。
- **手能用**：按名字点控件、截图、TTS / ASR、发 QQ、发空间、换头像。
- 代价也写在这里：桌宠那套是 WinForms，只在 Windows 上跑；`bridge.mjs` 那条线是**独立进程**，
  上下文不共享 —— 靠读文件和读原话来对齐，不是真共享。

许可：MIT（见 [`LICENSE`](LICENSE)）。
