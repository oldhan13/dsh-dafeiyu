# 踩过的坑

按"下次会再踩一次"的概率排。每条都是真撞过的，不是听说的。

## 1. PowerShell 变量名不分大小写（踩了两次）

```powershell
$ACT   = 'C:\...\activity.json'   # 想存路径
$script:act = 'idle'              # 状态字符串
# 这两个是同一个变量。
```

结果：`Test-Path $ACT` 变成 `Test-Path 'idle'`，永远 `False`，鱼就永远停在"待机"。
第一次犯是把顶栏高度 `$script:pHead` 和标题控件 `$script:phead` 当成两个名字，标题行整个消失。

**规矩**：起名之前先想一遍有没有同名近亲。路径类一律带 `FILE`/`DIR`/`PATH` 后缀。

## 2. DSH 的会话日志是 zstd **多帧**拼接

`~/.dsh/sessions/<工作区>/<会话>/session.v4.jsonl.zstd` 每次追加就是一帧。
`zlib.zstdDecompressSync(整个文件)` **只解第一帧** —— 你会得到 224 字节的会话头，然后以为文件是空的。

正确做法：按魔数 `28 b5 2f fd` 切帧，逐帧解，再拼起来。

```js
const M = Buffer.from([0x28, 0xb5, 0x2f, 0xfd])
let idx = [], i = 0
while ((i = buf.indexOf(M, i)) !== -1) { idx.push(i); i += 4 }
```

这个能力很值：**它是只读的**，所以面板那条线可以直接读 QQ 那条线的逐字原文，不用让宿主开权限。

## 3. Windows 11 会为 VBScript 弹提示

计划任务里用 `wscript.exe //B //Nologo xxx.vbs` 拿"无窗口"，在 Windows 11 24H2 上每次启动都会弹一个
`VBScript is scheduled for deprecation` 的提示框（需要点一下）。半小时一次的计划任务，就是半小时弹一次。

改法：任务动作换成隐藏窗口的 PowerShell，`.vbs` 整体退出这条链。

```powershell
$ps  = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$act = New-ScheduledTaskAction -Execute $ps -Argument '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "<脚本>"'
Set-ScheduledTask -TaskName '<任务>' -Action $act
```

⚠️ 别顺手改成 S4U / session 0：那种"判断用户在不在键盘前"的探针（`GetLastInputInfo`）在 session 0 会读错。

**排查口径**：Windows 弹窗类问题先看应用日志的 provider，比盯着屏幕快得多：

```powershell
Get-WinEvent -FilterHashtable @{LogName='Application'; StartTime=(Get-Date).AddHours(-2); Id=4096}
```

## 4. DSH 宿主的 `/api` 有浏览器信任校验

想从外部进程（比如 `bridge.mjs`）直接给宿主会话发消息，会遇到两道门：

- `/api` 与 `/` 都过 **browser-trust fence**：`Host` 必须是 loopback / 绑定地址 / 白名单，
  且 `Sec-Fetch-Site` 不能是 `cross-site`，`Origin` 要和 Host 同源。
- 真正的认证是 `/connect?token=<launchToken>&interactions=answer` 换一个 `dsh-auth-*` cookie。

所以外部进程接 /api，等于**伪造一个浏览器客户端**：能做，但 DSH 一升级就可能碎，且碎的表现是"她突然不回话"。
我们的选择是不接，改成读会话日志（见第 2 条）。

## 5. `.ps1` 的 BOM 只能有一个

两个 BOM 会让 `#requires` 被当成命令，桌宠直接起不来。
改完脚本一律跑一遍归一化 + 语法检查再重启，别手改。

## 6. 系统代码页 936：中文别上命令行

`powershell -Command "... 中文 ..."` 在 ACP=936 下会被拆坏。
要传中文就**走 UTF-8 临时文件**（`-File` + `Get-Content -Encoding UTF8`），源码保持纯 ASCII。

同一条也解释了另一个怪现象：子进程输出的中文进程名在父进程里变成乱码 —— 编码层，不是数据错。

## 7. 同一句话显示两遍

面板发出去的话如果同时又写进 `say.txt`，头顶气泡那条监听会把它递回面板，于是同一句出现两次。
两道保险都要在：请求带 `quiet:true`（不写 `say.txt`）+ 面板侧按前 40 字前缀去重。

## 8. 鱼的展开动画别逐帧改 `Bounds`

逐帧改窗口大小会每帧重排子控件（卡）、新露出的区域先画黑底（黑框）、上一层留下的气泡被挤成一条（绿框）。
正确做法：**一次摆到最终尺寸，只改 Region 一点点揭开**，再叠一个淡入。

## 9. `dsh headless` 里账号登录用不了（要用一次性的 overlay）

`dsh --profile headless "任务"` 是最省事的"后台 agent"：一次跑完就退出，stdout 就是结果。
但 headless 的基线层把 `authorization` / `credentials` / `deepseek-account` **三个服务关掉了**，
所以走账号登录（而不是 API key）的机器会直接失败：

```
dsh: warning: 1 entry did not activate
deepseek-account (...): pending (waiting for service: authorization)
dsh: ACCOUNT_SIGN_IN_REQUIRED: Sign in to DeepSeek to use the account provider.
```

**不用改自己的 profile**，每次带一份 overlay 把三个服务打开就行（`--patch` 只作用于这一次）：

```yaml
- id: authorization
  name: '@deepseek-ai/dsh-authorization'
  disabled: false
- id: credentials
  name: '@deepseek-ai/dsh-credentials-local'
  disabled: false
- id: deepseek-account
  name: '@deepseek-ai/dsh-deepseek-account-platform'
  disabled: false
```

```powershell
dsh --profile headless --patch .\agent-overlay.yml "把这件事办掉"   # 任务也可以从 stdin 读：结尾写 -
```

⚠️ 还有两个小坑：① 任务文本**别拼进命令行**，走 stdin（结尾的 `-`）最稳；
② 成功时 stdout 里会混进 `[llm-deepseek-account] model listing …` 这类诊断行，贴给人之前要滤掉。

