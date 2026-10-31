// catchup-pending.mjs —— 命令行看「断线期间没送到的话」，看过就 ack 掉。
//
//   node dafeiyu/tools/catchup-pending.mjs              看还没处理的（由旧到新）
//   node dafeiyu/tools/catchup-pending.mjs --json       同一件事，机器可读
//   node dafeiyu/tools/catchup-pending.mjs --all        连处理过的一起看（排查用）
//   node dafeiyu/tools/catchup-pending.mjs --done 1025756466 47719310
//   node dafeiyu/tools/catchup-pending.mjs --done-all   全部算处理过（一般别用，会连没看的也吞掉）
//   --file <path>                                       换个文件（测试用）
//
// ★ 这些消息**不会自动变成一轮对话** —— 插件那边只把它们记下来，不替我说什么。
//   什么时候答、怎么答（合成一句还是分开）由我自己判断，所以看完要 `--done` 掉，
//   否则它会一直挂在开场简报里。
// ★ ack 不删原文：文件只追加，内容是永久留底的。

import { ackEntries, formatEntry, openEntries, pendingPath } from '../lib/catchup-pending.mjs'

const argv = process.argv.slice(2)
const flag = (name) => argv.includes(name)
const valueOf = (name, fallback) => {
  const i = argv.indexOf(name)
  return i >= 0 && argv[i + 1] !== undefined && !argv[i + 1].startsWith('--') ? argv[i + 1] : fallback
}
const file = valueOf('--file', pendingPath())

if (flag('--done') || flag('--done-all')) {
  let ids = []
  if (flag('--done-all')) {
    ids = openEntries({ file, limit: 0 }).map((e) => e.id)
  } else {
    const i = argv.indexOf('--done')
    ids = argv.slice(i + 1).filter((x) => !x.startsWith('--'))
  }
  if (!ids.length) {
    console.log('没给 id：要么写 --done <id> [<id>…]，要么写 --done-all')
    process.exit(2)
  }
  const written = ackEntries(ids, { file })
  console.log(`ack ${written} 条（给的是 ${ids.length} 条，已经 ack 过的不重复写）`)
  process.exit(0)
}

const open = openEntries({ file, limit: flag('--all') ? 0 : undefined })

if (flag('--json')) {
  console.log(JSON.stringify({ file, count: open.length, entries: open }, null, 2))
  process.exit(0)
}

if (!open.length) {
  console.log('没有断线漏掉的话')
  process.exit(0)
}

console.log(`断线期间没送到的 ${open.length} 条（由旧到新，最旧的在上面）`)
console.log(`> 文件：${file}`)
console.log('> 它们没进过我的上下文 —— 答完了用 --done <id> 销掉，不然会一直挂在简报里')
console.log('')
for (const entry of open) {
  console.log('  ' + formatEntry(entry))
}
