# 安装

这套东西没有 `install.ps1` 的一键魔法，因为它在你的**工作区**里落地：DSH 的会话 cwd 就是它，
人格文件、记忆、脚本都按相对位置找。所以有一步是"把仓库放到正确的地方"。

下面以 `C:\Users\<你>\dsh-workspace` 为工作区举例，你自己的路径随便。

## 0. 前置

- Windows 10/11
- PowerShell 5.1（系统自带）
- Node.js **22+**（`node -v` 看一眼；`zstd` 解压那部分要 22.15 以上）
- DSH 0.2.x（`dsh --version`）
- 可选：NapCat（QQ 接入）、SiliconFlow key（语音 / 桌面那条线）

## 1. 放到工作区

```powershell
git clone https://github.com/c1overzz/dsh-dafeiyu.git C:\Users\<你>\dsh-workspace
cd C:\Users\<你>\dsh-workspace
```

之后的 DSH 会话、NapCat 那条线的 `cwd`，都应该指向这个目录。

## 2. 设两个身份

除了你的 QQ 号，其余东西都能自己发现。

```powershell
setx DAFEIYU_OWNER_QQ "你的QQ号"      # 谁的私聊算"主人"
setx DAFEIYU_BOT_QQ   "机器人QQ号"    # 她自己那个号的数字
```

设完要新开终端才生效。测试用：

```powershell
$env:DAFEIYU_OWNER_QQ = "123456"
node dafeiyu/group/gate.test.mjs
```

（那群/私聊的判定测试需要 `DSH_ONEBOT_LIB` 指向 `dsh-onebot-qq/lib`，见文件头注释。）

## 3. 装 DSH 插件

```powershell
dsh plugin --profile web add dsh-ledger-memory
dsh plugin --profile web add dsh-onebot-qq      # 只在要接 QQ 时
dsh plugin --profile web add dsh-voice-chat     # 可选：浏览器麦克风 + 朗读
```

刷 B 站是**可选**的独立插件：

```powershell
dsh plugin --profile web add github:c1overzz/dsh-bili-scroll
```

## 4. 放 profile 补丁

`profile/cordis.patch.yml` 是个模板，**要改三处**再合并进你的 profile：

```yaml
- id: dsh-onebot
  config:
    accessToken: "<NapCat 那边配的 token>"    # ← 改
    adminUsers: ["<主人QQ>"]                  # ← 改
    botQQ: "<机器人QQ>"                       # ← 改
```

合并位置：`%USERPROFILE%\.dsh\profiles\web\cordis.patch.yml`。
如果你原来就有一份，**别整体覆盖**，把 `dsh-onebot` 那一块并进去。

写完存盘，大约 3 秒内宿主会热重载（看 `~/.dsh/logs` 或直接试）；不行就重启 `dsh web`。

## 5. key 放哪

脚本不读环境变量里的密钥，只读文件：

```
%USERPROFILE%\.dsh\siliconflow-key.txt     # 一行，SiliconFlow 的 key
%USERPROFILE%\.dsh\onebot-token.txt        # 一行，NapCat 的 access token
```

这两份文件**永远不要**进 git。仓库的 `.gitignore` 已经把 `~/.dsh` 之外的常见坑挡住了，
但这俩本来就在仓库外面，安全。

## 6. 启动顺序

```powershell
# ① NapCat（要用 QQ 才需要）：用它自己的启动器登录小号，反向 WebSocket 拨到 8643
# ② DSH 宿主
dsh web
# ③ 鱼 + 后台循环
.\start-dafeiyu.cmd
```

`start-dafeiyu.cmd` 会拉起：桌宠（含面板）、bridge（3079）、心跳、群监听、主页（3077）、
以及挂一个每半小时的"台账瘦身"计划任务。

**注意工作区必须在 `~/.dsh` 之外**，否则 Windows ACL 沙箱会让子 shell 起不来
（报 `temp root 必须在 workspace 之外`）。`start-dsh-web.cmd` 里就是为这个把 cwd 钉死的。

## 7. 验收

按顺序过一遍，每步都该有反应：

1. 右下角出现一条鱼，在轻轻浮
2. 双击它 → 原地长成对话框；`Esc` 或 ✕ 收回去
3. 在对话框里说一句话 → 几秒后回复（`dafeiyu/desk/actions.log` 会多一行 `prompt <n> chars`）
4. 对着她说"打开记事本" → 鱼开始摆尾更快（`activity.json` 里 `state: acting`）
5. 十分钟不理她 → 闭眼、几乎不动
6. `Ctrl+Alt+D` → 面板开关
7. 右上角「声」点亮，再发一句 → 有声音（`dafeiyu/voice/` 下会多一个 mp3）

哪一步没反应，先看 `dafeiyu/pet/pet.log`（她自己的日志）和 `dafeiyu/desk/bridge.err.log`。

## 8. 常见故障

| 现象 | 原因 |
|---|---|
| 桌宠起不来，`pet.log` 里说 `#requires` 被当成命令 | `.ps1` 里有两个 BOM。改完脚本跑一遍 `pet-reload.ps1` 那类归一化 |
| 鱼一直不跟着状态动 | 见 PITFALLS 第 1 条：PowerShell 变量名不分大小写 |
| 面板里同一句话显示两遍 | `say.txt` 那条监听和面板的回复叠了，见 `panel.ps1` 顶部的去重说明 |
| QQ 不回 | 看 8643 有没有被拨进来；再看 profile 里 `dsh-onebot` 那块配置是否热重载了 |
| 每半小时弹一个 VBScript 提示 | 见 PITFALLS 第 3 条 |
