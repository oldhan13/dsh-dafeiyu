# 断线补收 —— 她说的话没送到时，话要留下来

> 一句话：**QQ 那条线断了，他发的话不该跟着一起消失。**

这个功能不在 `dsh-onebot-qq` 上游里（上游 0.9.3 的包里连 `catchup.js` 都没有）。
它是本地补丁 + 工作区代码拼起来的，打补丁见 [`patches/README.md`](../patches/README.md)。

## 它治的是什么病

QQ 通道的形状是「NapCat 主动拨号 + 宿主进程内监听」。宿主一停（重启 / 崩溃 / 关机），
或者插件层重载把反向 WS 关掉几十秒，**这段时间他发来的消息既不在 OneBot 的队列里、也没有人收**。

于是表现就是：他那边发出去了，她这边什么都没收到，等她回来时对话已经断片。

真实发生过（2026-10-29 → 10-31）：他发了两句，两天后她一个字都没看到。

## 根因：一条把「真断线」当「已回过」的守卫

早期版本里有这么一段：

```js
if (state.lastSeenMs > 0 && Date.now() - state.lastSeenMs > MAX_AGE_MS) {
    // 状态超过 6 小时 ⇒ 直接推进到 now、一条都不补
    state.lastSeenMs = Date.now()
}
```

写它是怕「停了几天的旧状态文件一接上，会把早就回过的旧对话重放一遍」。

**但这个假设是反的。** `lastSeenMs`（水位）是在**每一条正常入站**时推进的：

```js
connection.onMessage = (event) => {
    catchup.markSeen(Number(event?.time) * 1000)   // 先推水位
    bridge.handleInbound(event)                    // 再交给 bridge
}
```

所以宿主活着，水位必然新鲜；**水位变旧，只可能是因为宿主停了**。
也就是说「水位旧」和「已经回过了」是相反的两件事 —— 这条守卫把唯一能指出
「哪一段没人接」的信息当垃圾推进掉了，而且推进时不报错，只在日志里留一行：

```
2026-10-31 03:43:25  info  state stale (36h): advancing to now, no replay
```

## 现在的做法：按缺口长短分三档

| 缺口 | 怎么处理 | 为什么 |
| --- | --- | --- |
| ≤ 15 分钟 | 自动补成一次**正常入站**，照常回答 | 这就是「正聊着掉了一下」，他还在等 |
| 15 分钟 ～ 30 天 | **不自动补**，追加一行到待补收清单，等人来看 | 一条弹一次太吵；隔了几小时，语境早换了，该合成一句还是分开答是判断，不是代码能定的 |
| > 30 天 | 既不补也不进清单，只把水位推过去 | 没人想回一个月前的「在吗」 |

「轮询一直活着、水位却停在老地方」这种**真异常**（`markSeen` 那条线坏了）仍然推进水位、不补 ——
判据是两个时间戳的关系：

- `lastTickMs` 新（每分钟落盘）+ `lastSeenMs` 旧 ⇒ 是它坏了，别补；
- 两个一起变旧 ⇒ 宿主停过，**那正是要补的情形**。

## 待补收清单

文件：`<DSH_HOME 或 ~/.dsh>/onebot-catchup-pending.jsonl`，**只追加**：

```jsonl
{"id":"10001","ms":1700000000000,"from":"10000001","text":"在吗"}
{"ack":"10001"}
```

- 为什么不塞进 `.onebot-catchup.json`：那份是整份重写的（写 tmp 再 rename），
  而这份清单会被**另一个进程**读和 ack —— 两边一撞必丢一边。小行追加是原子的。
- **ack 不等于删除**：原文一直留着，只是不再出现在「还没处理」里。
- 写盘失败时**不推水位**（`addPending` 返回 `-1`）—— 推了那几条就永久没了。

看和销：

```powershell
node dafeiyu\tools\catchup-pending.mjs                    # 还没处理的，由旧到新
node dafeiyu\tools\catchup-pending.mjs --json
node dafeiyu\tools\catchup-pending.mjs --done 10001       # 处理完了
node dafeiyu\tools\catchup-pending.mjs --done-all
```

## 她怎么知道有欠账

清单落在 `~/.dsh/` 里，**没有任何东西会主动把它推进上下文**。
所以补丁在系统提示末尾加了一句（`prompt.js`）：

```
- ⚠ 有 N 条「断线期间没送到」的私聊（他说了，但从来没进过你的上下文）。
  先跑 node dafeiyu/tools/catchup-pending.mjs 看原文 …
```

**这一句是整条链路的开关**：没有它，补收做完了也没人看得见 ——
开场简报三十分钟才重生成一次，而人回来后的第一条消息往往就落在那三十分钟的窗口里。

另外 `make-brief.mjs` 的开头多了两节：

- 「断线期间没送到的」—— 有欠账时出现；
- 「私聊最后几轮（原话，双向）」—— 走 `get_friend_msg_history`，
  治的是另一个病：**换了会话 / 隔天醒来，一开口是空的，只能让他重讲一遍**。

## 怎么验

```powershell
$env:DSH_ONEBOT_LIB = "$env:USERPROFILE\.dsh\profiles\web\node_modules\dsh-onebot-qq\lib"
node dafeiyu\tools\catchup.test.mjs        # 16 条，全绿
```

真机验一次（会短暂断线，挑人不在的时候）：

1. 停宿主 → 手机发两条 → 等 20 分钟以上 → 起宿主；
2. **不该**自动弹两条回复；
3. `node dafeiyu\tools\catchup-pending.mjs` 里应该能看到那两条；
4. 答完 `--done` 销掉。

## 边界（写在前面，别指望它）

- **NapCat 整个死掉时，历史也拉不到** —— 只能等它回来再补，不是实时。
- **只补私聊、只补管理员**（`adminUsers`）。群消息有 `groupPolicy` 管，群里她自己看着。
- 自动补单次最多 10 条；更早的进清单。
- 补收的是「**没送到**」的消息，不是「没回复」的消息。她看过、决定不回，也算送到了。
