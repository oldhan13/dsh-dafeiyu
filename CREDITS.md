# 别人的东西

这个仓库里的代码是自己写的，但**跑起来靠的是别人做的零件**。这里把每一处"用到别人仓库的地方"标清楚，
免得看的人以为这些也是本仓库的产物。

## 一、运行时依赖（别人的仓库 / npm 包）

全部是**安装后才用到**，这个仓库里**没有**它们的源码，一份都没有 vendor 进来。

| 包 | 作者 | 许可 | 仓库 | 用在哪 |
|---|---|---|---|---|
| `@deepseek-ai/dsh`（DeepSeek Harness） | DeepSeek | 见其仓库 | github.com/deepseek-ai/deepseek-harness | 宿主：会话、工具、网页界面。整套东西都跑在它上面 |
| `dsh-ledger-memory` | 陈黛华 | MIT | github.com/18477514055/dsh-ledger-memory | 台账 / 决策卡 / 经验教训 / 逐字存档。`AGENTS.md` §九—§十 和 `tools/ledger-*.mjs` 都是围着它写的 |
| `dsh-onebot-qq` | mario841859784 | **BSD-3-Clause** | github.com/mario841859784/dsh-onebot | QQ 通道。`docs/PITFALLS.md` 里那条中间消息的坑、`group/` 的判定逻辑都跟它有关 |
| `dsh-voice-chat` | maoyuching | MIT | github.com/maoyuching/dsh-voice-chat | 浏览器麦克风 + 自动朗读（可选） |
| `@lijian-ui/dsh-im-gateway` | lijian-ui | MIT | github.com/lijian-ui/dsh-im-gateway | 微信那条通道（可选，本项目没深用） |
| `dsh-context` | bowenliang123 | Apache-2.0 | github.com/bowenliang123/dsh-context | 上下文压缩（可选） |
| `billion-context` | ranxianglei | MIT | github.com/ranxianglei/billion-context | 另一种上下文压缩（可选，二选一） |

⚠️ `dafeiyu/tools/catchup.test.mjs` 和 `dafeiyu/tools/mention.test.mjs` 会在运行时**直接 import `dsh-onebot-qq` 包里的模块**
（不是复制它的代码）。要跑这两个测试，用 `DSH_ONEBOT_LIB` 指向那个包的 `lib` 目录。
它用的是 BSD-3-Clause：**保留版权声明**这一条对它同样成立。

每个东西**各自擅长什么**，见 `README.md` 的「各家的长处」一节 —— 这一页只记**归属**，
不替别人评功，也不把自己的那一层说成是别人的地基。

## 二、另一位开发者的仓库（可选部件）

| 仓库 | 作者 | 许可 | 说明 |
|---|---|---|---|
| `c1overzz/dsh-bili-scroll` | c1overzz | MIT | 刷 B站那个插件。本仓库**只是提到它**（`README` 的可选部件、`docs/SETUP.md` 与 `install.ps1` 的一句提示），没有包含、没有改它 |

> 把关系写清楚：`c1overzz` 是**另一位开源开发者**，和本仓库作者（`oldhan13`）不是同一个人，
> 两边也没有从属或合作关系 —— 都是各自做各自的开源项目，碰巧这一套里有一件可选部件用得上他的。
> 这一节单独列出来，只是因为本仓库指向他的仓库；装不装、用不用，看你自己的判断。

## 三、外部程序与服务（不是代码依赖，但少了它们跑不起来）

| 东西 | 谁的 | 注意 |
|---|---|---|
| **NapCat** | 第三方 QQ 协议端 | 自己的许可；要自己装、自己承担账号风险。本仓库只调它的 HTTP 接口 |
| **SiliconFlow** | 第三方模型服务 | 语音合成 / 转写 / 桌面那条线的对话都走它。要自己的 key，按它的条款计费 |
| **QQ** | 腾讯 | 界面截图、聊天内容、头像 —— 都是别人的东西，别拿来做训练语料或再分发 |
| **B 站** | 哔哩哔哩 | 那个可选插件读的是标题 / 字幕 / 评论；**字幕和评论的版权不在你手上**，抓下来自己看可以，别转出去 |
| **维基文库** | Wikimedia | `docs/` 里引到的公版文本，遵循它自己的协议 |

## 四、明确没做的

- 没有 vendor 任何第三方源码（`dsh-bili-scroll` 里的 `vendor/` 也不在本仓库）
- 没有 fork 别人的代码再改
- 没有把别人写的 prompt / 人格文本搬进来 —— `AGENTS.md` 是从零写的
- `fish-draw.ps1` 是几何画法（几段贝塞尔 + 正弦漂移），没有用任何 Live2D / 骨骼动画库
