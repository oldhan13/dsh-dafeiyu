# 安装

两条路，选一条：

- **只要桌面上的那条鱼** → 走 0–3 步、直接跳到第 5 步。五分钟。
- **还要她在 QQ 里也在** → 中间多做第 4 步。再加十分钟。

每一步后面都写了**"做完这步你应该看到什么"**。没看到就先别往下走 —— 后面每一步都踩在前一步上。

---

## 0. 前置：三个版本号

```powershell
node -v                      # 要 v22 以上；zstd 解会话那段要 22.15+
dsh --version                # 要 0.2.x；没有就先 npm i -g @deepseek-ai/dsh
$PSVersionTable.PSVersion    # 系统自带 5.1 就够
```

**位置有一条硬规矩**：工作区**不能**放在 `%USERPROFILE%\.dsh` 里面。
Windows 的 ACL 沙箱要求临时目录在工作区之外，而 DSH 的临时目录默认就落在 `%USERPROFILE%` 下 ——
两者一叠，会话里的子 shell 起不来，报 `temp root 必须在 workspace 之外`。
`start-dsh-web.cmd` 已经把临时目录挪到了仓库旁边的 `..\.dafeiyu-temp`，你不用管；
但如果你习惯自己敲 `dsh web`，就得自己设 `TMP` / `TEMP`。

## 1. 把仓库放到工作区

```powershell
git clone https://github.com/oldhan13/dsh-dafeiyu.git C:\dsh-workspace
cd C:\dsh-workspace
```

为什么叫"工作区"而不是"程序目录"：DSH 的会话 cwd 就是它，人格文件、记忆、脚本全按**相对位置**去找。
所以 DSH 会话的 cwd、后面 NapCat 那条线的 cwd，都应该指向这个目录。

**做完这步你应该看到**：`Get-ChildItem` 里有 `AGENTS.md`、`dafeiyu\`、`docs\`、`profile\`、`install.ps1`。

## 2. 跑一次环境检查

```powershell
.\install.ps1 -SkipPlugins
```

它只做四件事，而且**不动**你的记忆、不删任何文件、不覆盖已有的 key：

1. 查 node / PowerShell / dsh 的版本，工作区位置对不对
2. 把两个身份写进**用户环境变量**（`setx`，要新开终端才生效）
3. 在 `%USERPROFILE%\.dsh\` 下建两个**空**文件：`siliconflow-key.txt`、`onebot-token.txt`
4. 把 `profile\cordis.patch.yml` 拷一份成 `cordis.patch.dafeiyu.sample.yml`（**不会**动你真正的 profile 配置）

要装 QQ 通道就把 `-SkipPlugins` 换成 `-WithQQ`；连语音插件一起要，再加 `-WithVoice`。

两个身份眼下填什么都行，接 QQ 时才用得上；先填了省得以后再来一次：

```powershell
setx DAFEIYU_OWNER_QQ "你的QQ号"      # 谁的私聊算"主人"
setx DAFEIYU_BOT_QQ   "机器人QQ号"    # 她自己那个号
```

**做完这步你应该看到**：最后一行 `✓` 或者一段 `[!!]`。有 `[!!]` 就先解决它。

## 3. key（只桌面也要，语音和对话都走它）

脚本不读环境变量里的密钥，**只读文件**，一行一个：

```
%USERPROFILE%\.dsh\siliconflow-key.txt     # SiliconFlow 的 key，语音合成 / 转写 / 桌面那条线都用它
%USERPROFILE%\.dsh\onebot-token.txt        # NapCat 的 access token（只接了 QQ 才需要）
```

这两份文件在仓库**外面**，`.gitignore` 也管不到它们 —— 但也正因如此，**永远别把它们拷进仓库**。

**做完这步你应该看到**：`Get-Content $env:USERPROFILE\.dsh\siliconflow-key.txt` 打得出一行 key。

## 4. 接 QQ（可选，十分钟）

### 4.1 装通道插件

```powershell
dsh plugin --profile web add dsh-onebot-qq
```

### 4.2 起 NapCat

装 [NapCat](https://napcat.napneko.icu/)，用**一个小号**登录（别拿主号），然后：

- 反向 WebSocket 指向 `ws://127.0.0.1:8643`
- HTTP 服务开在 `3000`（`start-dafeiyu.cmd` 靠它判断"她在不在线"）
- access token 填一个你自己编的字符串，**同时**写进 `%USERPROFILE%\.dsh\onebot-token.txt`

### 4.3 补丁：改三个占位符

```powershell
notepad "$env:USERPROFILE\.dsh\profiles\web\cordis.patch.dafeiyu.sample.yml"
```

```yaml
- id: dsh-onebot
  config:
    accessToken: "<NapCat 那边配的 token>"    # ← 改
    adminUsers: ["<主人QQ>"]                  # ← 改
    botQQ: "<机器人QQ>"                       # ← 改
```

改完把这块**并进** `%USERPROFILE%\.dsh\profiles\web\cordis.patch.yml` ——
你原来就有一份的话**别整体覆盖**，只把 `dsh-onebot` 这一块加进去。
存盘后约 3 秒宿主会热重载；没反应就 `dafeiyu\tools\restart-host.cmd` 重启一次。

**做完这步你应该看到**：QQ 给那个小号发一句话，几秒后有回复；`netstat -ano | findstr 8643` 有一条 ESTABLISHED。

## 5. 启动：两个窗口

```powershell
# 窗口 A —— 宿主。它会一直占着，别关
.\start-dsh-web.cmd

# 窗口 B —— 她。跑完就可以关掉这个窗口
.\start-dafeiyu.cmd
```

`start-dafeiyu.cmd` 会**缺什么补什么**，已经活着的不重复起。它管这几样：

| 它拉起的 | 端口 | 干什么 |
|---|---|---|
| DSH 宿主 | `3080` 网页 · `8643` QQ 反向 WS | 会话、工具、网页界面 |
| NapCat | `3000` | 那个 QQ 小号的客户端（要装、要登录） |
| 鱼 + 面板 | — | 屏幕右下角那只，双击展开成对话框 |
| 桌面桥 `bridge.mjs` | `3079` | 面板那条线的大脑（独立进程） |
| 主动循环 `heartbeat.mjs` | — | 每 8–13 分钟醒一次，自己决定说不说 |
| 群随听 `watch.mjs` | `3078` | 群里全听得见，但只接该接的 |
| 她的主页 `serve.mjs` | `3077` | `http://127.0.0.1:3077/` |
| 台账瘦身（计划任务） | — | 每 30 分钟把台账压回预算内、重写开场简报 |

也可以只问不干：

```powershell
.\start-dafeiyu.cmd -Status      # 现在谁活着
.\start-dafeiyu.cmd -NoHost      # 宿主你自己开着，别动它
```

**做完这步你应该看到**：末尾那张 `=== 现在 ===` 里，`宿主` / `桌宠` / `循环` / `主页` 都是好的，
退出码是 0（缺东西会是 1，方便快捷方式判断）。

## 6. 验收

按顺序过一遍，每步都该有反应：

| # | 做什么 | 应该看到什么 |
|---|---|---|
| 1 | 看右下角 | 一条半透明的小鱼在轻轻浮 |
| 2 | 双击它 | 原地长成对话框；`Esc` 或 ✕ 收回成鱼 |
| 3 | 对话框里说一句话 | 几秒后回复；`dafeiyu\desk\actions.log` 多一行 `prompt <n> chars` |
| 4 | 说「打开记事本」 | 鱼摆尾变快、偶尔吐泡；`dafeiyu\pet\activity.json` 里 `state: acting` |
| 5 | 十分钟不碰它 | 闭眼、几乎不动；鼠标挪过去会醒，眼珠跟着偏 |
| 6 | 按 `Ctrl+Alt+D` | 面板开关 |
| 7 | 点右上角「声」，再说一句 | 有声音；`dafeiyu\voice\` 下多一个 mp3 |

最后再确认一遍后台都认得出来：

```powershell
.\stop-dafeiyu.cmd -Status
```

五行都是 `[ok]` 或 `[--]`（`[--]` 表示那个没起，不算错，比如没接 QQ），就不算 `[!!]`。

## 7. 收工、重启

```powershell
.\stop-dafeiyu.cmd            # 鱼 + 后台循环全停
.\stop-dafeiyu.cmd -Status    # 只看，不动
```

宿主不归它管 —— 那是窗口 A，自己关（`Ctrl+C` 或点叉）。
改完 profile 或插件、又不想手动关宿主：

```powershell
dafeiyu\tools\restart-host.cmd
```

## 8. 卡住了

先看两个日志，八成就够了：`dafeiyu\pet\pet.log`（她自己记的）、`dafeiyu\desk\bridge.err.log`（桌面那条线）。

| 现象 | 原因 / 怎么办 |
|---|---|
| 鱼没出来，`pet.log` 说 `#requires` 被当成命令 | `.ps1` 里出现了**两个** BOM。跑 `dafeiyu\pet\pet-reload.ps1`：它只留一个 BOM、语法检查、再把桌宠重启 |
| 会话里子 shell 起不来：`temp root 必须在 workspace 之外` | 工作区在 `%USERPROFILE%` 下而 TMP 也在那儿。用 `start-dsh-web.cmd` 起宿主，它会把 TMP 挪到仓库旁边 |
| 鱼一直当自己闲着，不跟状态动 | PowerShell 变量名不分大小写惹的祸（`$ACT` 撞了 `$ACTFILE`）。见 [PITFALLS 第 1 条](PITFALLS.md) |
| 面板里同一句话显示两遍 | `say.txt` 那条监听和面板回复的监听叠了。`panel.ps1` 顶部有两道去重，别拆 |
| 双击鱼没反应 | `bridge.mjs` 没起（3079）。看 `dafeiyu\desk\bridge.err.log` |
| QQ 不回 | 8643 有没有被拨进来；补丁里 `dsh-onebot` 那块热重载了没有；token 两边一致不一致 |
| 每半小时弹一个「VBScript 已弃用」 | 老版本留下的计划任务用 `wscript` 跑 vbs。从当前版本跑一次 `.\start-dafeiyu.cmd` 会把动作换成隐藏 PowerShell；还弹就看 [PITFALLS 第 3 条](PITFALLS.md) |
| 端口被占 / `EADDRINUSE` | 别的实例还活着。别叠第二个宿主：`netstat -ano \| findstr 3080` 找出 pid 再决定 |
| `node -v` 是 22 以下 | 会话记录解不开（多帧 zstd）。升到 22.15 以上 |

## 9. 拆掉

```powershell
.\stop-dafeiyu.cmd                                    # 先停
schtasks /Delete /TN DaFeiYu-LedgerTidy /F            # 删计划任务（不删会一直跑，找不到文件就报错）
[Environment]::SetEnvironmentVariable('DAFEIYU_OWNER_QQ', $null, 'User')
[Environment]::SetEnvironmentVariable('DAFEIYU_BOT_QQ',   $null, 'User')
```

然后把工作区目录和 `%USERPROFILE%\.dsh\siliconflow-key.txt` / `onebot-token.txt` 删掉就干净了。
她不会自己删任何东西 —— 记忆、日记都在你那个工作区目录里，留着还是删掉，你自己定。
