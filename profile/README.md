# profile 参考配置

这里不是能直接用的文件，是**照着抄**的模板：

- `package.json` —— profile 需要哪些 bundle（`dsh plugin add` 会自动维护真正那份，这份只是让人看清依赖关系）
- `cordis.patch.yml` —— 那个 profile 的 patch 层里，和大肥鱼有关的部分

真正生效的文件在 `%USERPROFILE%\.dsh\profiles\<你的profile>\` 下。

## 三处必须改

`cordis.patch.yml` 里 `dsh-onebot` 那块的 `accessToken` / `adminUsers` / `botQQ` 都是占位符，
换成你自己的。其余（端口、中间消息开关）可以直接用。

## 关于 `interimMessages` / `interimRecall`

这两个开关决定"她在思考时，中间那几句要不要发到 QQ"。默认值会让长回合变成：
先发几句 → 90 秒后自动撤回 → 回合结束再拼一张带编号的"本轮中间记录"图卡 → 撤回原文 → 发最终回复。

看着像故障，其实是默认值。要"中间能看见、但不撤回、也不来那张编号卡"：

```yaml
interimMessages: true    # 中间话实时发
interimRecall: false     # 不发定时撤回
```

⚠️ 别把 `interimMessages` 关成 false —— 那是把中间话整个关掉，长回合中途会一片安静。
