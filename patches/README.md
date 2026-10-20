# patches —— 打在 `dsh-onebot-qq` 上的两处本地改动

大肥鱼有两件事，上游插件不做，所以这里放两个补丁，**装的时候自动打上**（`install.ps1` 会调 `apply-patches.mjs`）。
它们是**整段锚点替换**，不是 diff：找不到锚点就报错退出，宁可不打，也不硬改。

| 补丁 | 改哪个文件 | 做了什么 |
| --- | --- | --- |
| `poke-inbound` | `connection.js` | 戳一戳（`notice/notify/poke`）翻成一条 `[戳一戳]` 消息，走正常入站管线。只认「目标是本账号」的，群里别人互戳、自己戳自己直接丢 |
| `split-private-replies` | `outbound.js` | 私聊里一段多行回复，按行拆成 2–8 条发（间隔 320ms）。每行超过 160 字、或超过 8 行，就整段发，不刷屏 |

## 为什么放在这里

这俩改的是 `node_modules/dsh-onebot-qq` 里的文件 —— `npm i` / `dsh plugin add` 一升级就没了。
放成可重跑的脚本，升级后跑一次就回来。

## 怎么打

```powershell
# 装的时候自动打（install.ps1 里已经接了）
.\install.ps1 -OwnerQQ <你的号> -BotQQ <小号> -WithQQ

# 单独打 / 单独查
node patches\apply-patches.mjs            # 默认 ~/.dsh/profiles/web
node patches\apply-patches.mjs --profile web
node patches\apply-patches.mjs --dir "C:\Users\<你>\.dsh\profiles\web\node_modules\dsh-onebot-qq\lib"
node patches\apply-patches.mjs --check    # 只看状态，不写文件
```

- **幂等**：已经打过会跳过，可以反复跑。
- **会备份**：每次真改之前存一份 `<文件>.orig-<时间戳>`。
- **过语法检查**：打完 `node --check` 不过就自动还原。
- 退出码：`0` 全就位 · `1` 有补丁打不上（打印原因）· `2` 找不到插件。

## 打完要重启

插件模块在宿主进程里是有缓存的 —— **改完文件，重启 `dsh web` 才生效**。
（只加注释、不动 `cordis.patch.yml` 的写法不会触发重载，这一点栽过。）

## 插件升级后

`dsh plugin add dsh-onebot-qq` 之类的升级会把这两个文件覆盖掉 ⇒ 补丁消失。
升级完重跑一次：

```powershell
node patches\apply-patches.mjs
```

如果报「找不到锚点」，说明上游把这段代码改了 —— 那时要照着新代码重新对一遍锚点，**别硬打**。
