# 踩过的坑

按"下次会再踩一次"的概率排。每条都是真撞过的，不是听说的。

## 1. PowerShell 变量名不分大小写（踩了三次）

```powershell
$ACT   = 'C:\...\activity.json'   # 想存路径
$script:act = 'idle'              # 状态字符串
# 这两个是同一个变量。
```

结果：`Test-Path $ACT` 变成 `Test-Path 'idle'`，永远 `False`，鱼就永远停在"待机"。
第一次犯是把顶栏高度 `$script:pHead` 和标题控件 `$script:phead` 当成两个名字，标题行整个消失。

第三次（2026-10-20 晚，加拖文件功能时）最阴：输入条高度是 `$script:pFoot = 84`，
我新加一个控件引用 `$script:pfoot = $null` —— 同一个变量，**直接把它清零了**。
表现不是报错：面板底部的输入条高度变成 0、正正好停在窗口下沿外，整条输入框（连同 `+`/`说`/`发`）
被裁到窗口外面，看着像"功能没做"。

**规矩**：起名之前先想一遍有没有同名近亲。路径类一律带 `FILE`/`DIR`/`PATH` 后缀，控件类带 `Ctl`。
数字和控件**绝不**只靠大小写区分 —— 那是同一个名字。

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

**反过来也踩过（2026-10-23）**：用编辑器 API 改完 `.ps1`，它把文件**写成了不带 BOM 的 UTF-8** ——
而 `[Parser]::ParseFile` 于是按系统代码页 936 去读，中文全变乱码，报出三十多条
`Missing ')'` / `string is missing the terminator` 的**假错**，看着像脚本被改烂了，实际一个字都没错。

**判据**：`.ps1` 改完**一律跑那个 reload 脚本**（它补 BOM、用对的编码查语法、再重启），
别拿 `ParseFile` 直接对一个刚被编辑器写过的文件下结论。BOM 状态用字节前三位 `EF BB BF` 验，别靠眼睛。

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

## 10. `wscript` 去 Run 一个 `.cmd`，会弹「无法验证发布者」

和第 3 条是同一种病：**弹窗的根源不是"窗口没藏好"，是让 ShellExecute 去启动一个脚本文件。**

表现：`无法验证发布者。你确定要运行此软件吗？`，里面写着
`名称: ...\dafeiyu\tools\ledger-tidy.cmd`、`类型: Windows 命令脚本`。
两条链都撞过：

- **每半小时一次**：计划任务 → `wscript.exe //B` → vbs 里 `sh.Run "...\ledger-tidy.cmd"`
- **每次开机一次**：启动文件夹的 `.lnk` → `wscript.exe start-silent.vbs` → 同样 `sh.Run` 一个 `.cmd`

`.cmd` / `.bat` 在 Attachment Manager 眼里是"高风险脚本类型"，经 ShellExecute 启动就要你确认一次 ——
**跟有没有 Mark-of-the-Web 无关**（`dir /r` 查不到 `Zone.Identifier` 也一样弹）。

改法只有一条原则：**别让 ShellExecute 启动脚本，直接起一个签过名的 exe。**

```powershell
# 计划任务：隐藏 PowerShell 跑 .ps1
$act = New-ScheduledTaskAction -Execute 'powershell.exe' `
  -Argument '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "...\ledger-tidy-hidden.ps1"'
Set-ScheduledTask -TaskName 'DaFeiYu-LedgerTidy' -Action $act

# 开机自启：快捷方式直接指向 powershell.exe，而不是 wscript
$s = (New-Object -ComObject WScript.Shell).CreateShortcut("$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup\DaFeiYu.lnk")
$s.TargetPath = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
$s.Arguments  = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "...\start-dafeiyu.ps1"'
$s.Save()
```

在 `.ps1` 里用 `& "...\x.cmd"` 调 `.cmd` 是**没问题**的：那走 cmd.exe 直接执行，不经 ShellExecute。

排查口径：先 `schtasks /Query /TN <任务> /V /FO LIST | findstr "Task To Run"` 看动作是不是还挂着 wscript，
再看启动文件夹里有没有指着 vbs 的快捷方式 —— 两处都换掉，弹窗才真的没了。

## 11. 「先把 id 回给调用方，再登记活儿」⇒ 那 1.2 秒里全是 404（2026-10-23）

面板那条线是**轮询**的：`POST /say` 拿到 id，再拿这个 id 去 `GET /reply` 取结果。
原来写的是「先回 id，合并窗口（1.2 秒）结束时才把 job 放进 Map」。中间那一秒多，面板来问就是 `404`，
它按"没有这个 id"处理、**当场放弃** —— 而后台那一轮其实好好跑到了第 7 步，答复没人接，整轮白跑。

用户看到只有一句话：**「回复断了」**；日志里只有一行 `panel reply failed: (404)`。

**规矩**：凡是「先回执、后台干活」的接口，**回执发出之前必须把"活儿在哪取"也登记好**。
验的时候也不能只验"请求发出去了"，要验"拿那个 id 能不能取到东西"。

## 12. `127.0.0.1` 不等于「只有我能连」—— 浏览器就是本机进程（2026-10-23）

桌面桥只绑 `127.0.0.1`，很容易觉得"外网连不上，所以安全"。但**浏览器跑在本机**：
打开的任何网页都能指使它往 `127.0.0.1:3079` 发请求，而桥后面挂着 `run`（任意 PowerShell）。

实测：`POST /say` 带 `Content-Type: text/plain` 直接被受理 —— 那属于"简单请求"，**不发预检**，
浏览器读不到回执，但副作用已经发生。

**修法两道一起上**：① 一个 token（`dafeiyu/desk/token.txt`，桥起时没有就现生成，面板读同一个文件）；
② 强制 `application/json`（跨站发它必须先问预检，而服务不答 `OPTIONS` ⇒ 浏览器自己就把请求掐了）。
`/health` 留开放 —— 鱼每几秒探一次，它只回工具个数。

## 13. NapCat 不推 `message_sent`：自己说的话得自己记（2026-10-23）

群里那份 `raw.jsonl` 落了五千多条，`self` 却一直是 **0** —— 因为这台 NapCat 根本不推
`message_sent`（自己发出去的消息事件）。于是"群里刚才在聊什么"只剩别人的一侧：
她翻回去会以为自己没说过话，把同一句再说一遍。

**做法**：`sendGroup()` 发成功之后，自己往 `raw.jsonl` 补一行 `self: true`（带 message_id）。
⚠️ 缺口仍在：从**别的进程**（QQ 那条会话）直接发进群的话，这份日志里没有 —— 用之前先看这一条。

## 14. `vw.py plan --out` 要的是**文件**，不是目录（2026-10-23）

现象：`video-watch-plus` 的 `plan` 子命令里写的是 `open(args.out, "w")` —— 传目录进去直接
`PermissionError: [Errno 13] Permission denied`（Windows 上表现为这条 traceback）。
它静默失败、`report` 又依赖 `plan` 产出的 `shotlist.json`，所以整条链上**只有报告变成 null**，
图板和量测全都正常 —— 最容易当成"上游不支持"放过去。

**做法**：`plan --out <workDir>/shotlist.json`（文件路径，或干脆不给 `--out`，它默认写到 timeline 旁边）；
报告再 `report timeline.json shotlist.json --out report.md`。
