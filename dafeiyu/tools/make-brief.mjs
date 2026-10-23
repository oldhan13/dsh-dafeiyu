// make-brief.mjs —— 生成「开场简报」：让两个我醒来时不用从零开始。
//
// 读：memory/facts.md、memory/diary/*.md（最近几篇）、people/<主人QQ>.md、
//     relay/web.md + relay/qq.md（各自最后一条）、state/presence.json（有就看）
// 写：memory/brief.md（纯文本，无 BOM，总量硬上限 BUDGET 字符）
//
// 由 DaFeiYu-LedgerTidy 那条计划任务顺带每 30 分钟跑一次，也可以手动跑。
// 规矩：**别手改 brief.md** —— 它是生成物，改了下一轮就被覆盖。

import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { tailMessages, format, readNames } from '../lib/group-chat.mjs'

const HERE = path.dirname(fileURLToPath(import.meta.url))
const DAFEIYU = path.resolve(HERE, '..')
const BUDGET = 9000

const p = (...xs) => path.join(DAFEIYU, ...xs)

function readIf(file) {
  try { return fs.readFileSync(file, 'utf8') } catch { return '' }
}
function stripBom(s) { return s.replace(/^\uFEFF/, '') }
// 日记是追加写的：最新的话在末尾，所以取尾部
function tail(s, n) {
  s = s.replace(/\r\n/g, '\n').trim()
  if (s.length <= n) return s
  const cut = s.slice(s.length - n)
  const i = cut.indexOf('\n')
  return '…（前略）\n' + (i >= 0 ? cut.slice(i + 1) : cut)
}
// 去掉一级标题行，section 标题外面自己加
function dropH1(s) {
  return s.replace(/^#\s.*$/m, '').replace(/\n{3,}/g, '\n\n').trim()
}
// 嵌进来的内容把标题降级，免得它自己的 ## 冒充简报的顶层小节
function demote(s, add) {
  let inFence = false
  return s.split('\n').map(line => {
    if (/^\s*```/.test(line)) { inFence = !inFence; return line }
    if (inFence) return line
    const m = /^(#{1,6})(\s)/.exec(line)
    if (!m) return line
    return '#'.repeat(Math.min(m[1].length + add, 6)) + line.slice(m[1].length)
  }).join('\n')
}
function lastEntry(md) {
  const blocks = stripBom(md).split(/^(?=## )/m).filter(b => b.trimStart().startsWith('## '))
  return blocks.length ? blocks[blocks.length - 1].trim() : ''
}

const now = new Date()
const stamp = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}-${String(now.getDate()).padStart(2, '0')} ` +
  `${String(now.getHours()).padStart(2, '0')}:${String(now.getMinutes()).padStart(2, '0')}`

const parts = []
parts.push(`# 开场简报`)
parts.push(`> 自动生成于 ${stamp}（make-brief.mjs）。**别手改这个文件** —— 下一轮会被覆盖。`)
parts.push(`> 三十秒看完它，再开口。想细看再去翻日记原文。`)
parts.push('')

// 1. 他这个人
const peopleDir = p('people')
let owner = ''
try {
  const f = fs.readdirSync(peopleDir).find(n => n.startsWith(process.env.DAFEIYU_OWNER_QQ || ''))
  if (f) owner = dropH1(stripBom(readIf(path.join(peopleDir, f))))
} catch {}
parts.push('## 他这个人')
parts.push(owner ? tail(demote(owner, 1), 1600) : '（people/' + (process.env.DAFEIYU_OWNER_QQ || '') + '.md 不存在 —— 该建了）')
parts.push('')

// 2. 最近几天的事
const diaryDir = p('memory', 'diary')
let diaries = []
try {
  diaries = fs.readdirSync(diaryDir).filter(n => n.endsWith('.md')).sort().reverse().slice(0, 3)
} catch {}
parts.push('## 最近几天')
if (!diaries.length) {
  parts.push('（还没有日记）')
} else {
  for (const name of diaries) {
    const body = demote(dropH1(stripBom(readIf(path.join(diaryDir, name)))), 2)
    const cap = name === diaries[0] ? 2200 : 900
    parts.push(`### ${name.replace(/\.md$/, '')}`)
    parts.push(tail(body, cap) || '（空）')
    parts.push('')
  }
}

// 3. 不会变的事
const facts = dropH1(stripBom(readIf(p('memory', 'facts.md'))))
parts.push('## 不会变的事（长期事实）')
parts.push(tail(demote(facts, 1), 1800) || '（memory/facts.md 为空）')
parts.push('')

// 4. 两条线上的话
const webLast = lastEntry(readIf(p('relay', 'web.md')))
const qqLast = lastEntry(readIf(p('relay', 'qq.md')))
if (webLast || qqLast) {
  parts.push('## 两条线上的话（relay 最新一条）')
  if (qqLast) { parts.push('### QQ 那边'); parts.push(tail(demote(qqLast, 2), 700)); parts.push('') }
  if (webLast) { parts.push('### 网页这边'); parts.push(tail(demote(webLast, 2), 700)); parts.push('') }
}

// 4.5 桌面面板那边刚说的话（面板是独立进程，它的上下文只在这儿被人看见）
const deskHist = readIf(p('desk', 'history.jsonl'))
const deskLines = deskHist.split('\n').filter(Boolean).map(l => {
  try { return JSON.parse(l) } catch { return null }
}).filter(Boolean).slice(-6)
if (deskLines.length) {
  const hhmm = at => {
    const d = new Date(at)
    return isNaN(d) ? '' : `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`
  }
  const clip = s => {
    s = String(s || '').replace(/\s+/g, ' ').trim()
    return s.length > 140 ? s.slice(0, 140) + '…' : s
  }
  parts.push('## 桌面面板那边刚说的话（最近几条，最下面最新）')
  for (const it of deskLines) {
    parts.push(`- ${hhmm(it.at)} ${it.role === 'user' ? '他' : '我'}：${clip(it.text)}`)
  }
  parts.push('')
}

// 4.6 群里刚在聊什么
// 他 2026-10-23 说的：「群里没 @ 她的时候，她也想看得见——不回，就想知道你们在聊什么」。
// 数据只有一份：group/raw.jsonl（watch.mjs 每收一条就落一行，不只落叫她的）。
// 这里只放最近一小时的最后 10 条 —— 够她知道"刚才在聊什么"；想看更细更新的，她自己跑 tools/group-peek.mjs。
{
  const msgs = tailMessages({ minutes: 60, limit: 10 })
  if (msgs.length) {
    parts.push('## 群里刚在聊什么（最近一小时，没叫你也在里面）')
    parts.push('> 只为了知道，不是叫你接话。想看更细的：`node dafeiyu/tools/group-peek.mjs -m 180 -n 40`')
    for (const m of msgs) parts.push('- ' + format(m, { names: readNames(), clip: 60 }))
    parts.push('')
  }
}

// 5. 现在
const presence = readIf(p('state', 'presence.json'))
parts.push('## 现在')
if (presence.trim()) {
  parts.push('```json')
  parts.push(presence.trim().slice(0, 500))
  parts.push('```')
} else {
  parts.push('（还没有 presence.json —— 他在不在电脑前，得自己看）')
}

let out = parts.join('\n').replace(/\n{4,}/g, '\n\n\n').trim() + '\n'
if (out.length > BUDGET) {
  out = out.slice(0, BUDGET)
  out = out.slice(0, out.lastIndexOf('\n')) + '\n\n…（简报超过 ' + BUDGET + ' 字符，被截断；细节去看日记原文）\n'
}

fs.writeFileSync(p('memory', 'brief.md'), out, 'utf8')
console.log(`brief ok ${stamp} -> memory/brief.md (${out.length} chars)`)
