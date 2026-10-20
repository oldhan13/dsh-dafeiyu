// ledger-archive.mjs -- 把 LEDGER.md 中间的「逐轮增量/记号」搬进归档，只留头部现状。
//
// 为什么要有这个：台账只该放「现在是什么状态」，但两个会话每轮都往里追加
// 「本轮增量（…）」和「本轮记号（…）」，一天下来 1692 行，每轮整份注入。
// 归档是只追加的：搬走的东西进 _ledger-archive/YYYY-MM/weekN/LEDGER-archive.md，
// 原文一个字都不删，只是不在活跃台账里了。
//
// 用法：
//   node ledger-archive.mjs             # 只看会搬多少行，不写
//   node ledger-archive.mjs --apply     # 真搬
//   node ledger-archive.mjs --apply --head-lines 63
//
// 规则：
//   · 头 = 文件开头到第一个「逐轮」小标题之前（--head-lines 可覆盖到指定行号，含）
//   · 尾 = 从「## 变更登记」起的全部（插件自己维护的，不能搬）
//   · 中间 = 头尾之间的一切 → 追加进归档
//   · 头尾原样保留，顺序不变；归档文件只 append，不 rewrite

import { appendFileSync, existsSync, mkdirSync, readFileSync, writeFileSync, copyFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..')
const LEDGER = join(ROOT, 'LEDGER.md')

const argv = process.argv.slice(2)
const apply = argv.includes('--apply')
const hlIdx = argv.indexOf('--head-lines')
const forcedHead = hlIdx >= 0 ? Number(argv[hlIdx + 1]) : 0

const ROUND_HEAD = /^##\s*(本轮增量|本轮记号|记号|补记)/
const CHANGE_HEAD = /^##\s*变更登记/

const text = readFileSync(LEDGER, 'utf8')
const lines = text.split(/\r?\n/)

let roundStart = -1
for (let i = 0; i < lines.length; i += 1) {
  if (ROUND_HEAD.test(lines[i])) { roundStart = i; break }
}
let changeStart = -1
for (let i = lines.length - 1; i >= 0; i -= 1) {
  if (CHANGE_HEAD.test(lines[i])) { changeStart = i; break }
}

if (roundStart < 0) {
  console.log('没有找到「本轮增量/记号」小标题 —— 台账已经是干净的，什么都不做。')
  process.exit(0)
}
if (changeStart < 0) changeStart = lines.length

const headEnd = forcedHead > 0 ? forcedHead : roundStart // exclusive index in `lines`
const head = lines.slice(0, headEnd)
const middle = lines.slice(headEnd, changeStart)
const tail = lines.slice(changeStart)

// 兜底：中间不能空，头不能空
if (middle.length === 0) { console.log('中间是空的，不用搬。'); process.exit(0) }
if (head.length === 0) { console.log('头是空的，拒绝执行（怕把整份搬走）。'); process.exit(1) }

const now = new Date()
const ymd = now.getFullYear() + '-' + String(now.getMonth() + 1).padStart(2, '0')
const week = Math.ceil(now.getDate() / 7)
const archDir = join(ROOT, '_ledger-archive', ymd, 'week' + week)
const archFile = join(archDir, 'LEDGER-archive.md')

const stamp = now.getFullYear() + '-' + String(now.getMonth() + 1).padStart(2, '0') + '-' +
  String(now.getDate()).padStart(2, '0') + ' ' +
  String(now.getHours()).padStart(2, '0') + ':' + String(now.getMinutes()).padStart(2, '0')

const batch = [
  '',
  '---',
  '',
  '## 归档批次 ' + stamp + '（ledger-archive.mjs）',
  '',
  '> 来源：`LEDGER.md` 第 ' + (headEnd + 1) + '–' + changeStart + ' 行（共 ' + middle.length + ' 行）。',
  '> 原因：活跃台账上限 300 行，实际已到 ' + lines.length + ' 行。原文逐字搬过来，未改写。',
  '',
  ...middle,
  '',
].join('\n')

console.log('活跃台账：' + lines.length + ' 行')
console.log('  头（保留）：1–' + headEnd + ' 行')
console.log('  中（搬走）：' + (headEnd + 1) + '–' + changeStart + ' 行，共 ' + middle.length + ' 行 / ' + Buffer.byteLength(middle.join('\n'), 'utf8') + ' 字节')
console.log('  尾（保留）：' + (changeStart + 1) + '–' + lines.length + ' 行')
console.log('归档目标：' + archFile)
console.log('搬完后活跃台账约 ' + (head.length + tail.length) + ' 行')

if (!apply) {
  console.log('\n（dry run，什么都没写；加 --apply 才真搬）')
  process.exit(0)
}

mkdirSync(dirname(archFile), { recursive: true })
const before = existsSync(archFile) ? Buffer.byteLength(readFileSync(archFile), 'utf8') : 0
appendFileSync(archFile, batch + '\n', 'utf8')
const after = Buffer.byteLength(readFileSync(archFile), 'utf8')

// 备份活跃台账再改写：出问题能从 .bak 拿回来
const bak = LEDGER + '.bak-' + now.getTime()
copyFileSync(LEDGER, bak)

const next = [...head, ...tail].join('\n').replace(/\n{3,}/g, '\n\n')
writeFileSync(LEDGER, next, 'utf8')

console.log('\n已归档。')
console.log('  归档文件：' + before + ' → ' + after + ' 字节（+' + (after - before) + '）')
console.log('  活跃台账：' + lines.length + ' → ' + next.split('\n').length + ' 行')
console.log('  备份：' + bak)
