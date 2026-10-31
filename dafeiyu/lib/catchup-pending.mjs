// catchup-pending.mjs —— 读「断线期间没送到的话」那份清单。
//
// 谁写：插件的 `dsh-onebot-qq/lib/catchup.js`。它每 20 秒问一次 NapCat 的私聊历史，
//       把「水位之后、缺口超过 15 分钟、又不是太老」的消息**追加**成一行 JSON。
//       它只追加，不读、不删、不 ack —— 那样插件被升级覆盖时，我们损失最小。
//
// 谁读：我自己（`dafeiyu/tools/catchup-pending.mjs`）和开场简报（`make-brief.mjs`）。
//       所以「怎么读、算不算处理过」这件事留在工作区，跟插件无关。
//
// 文件形状（`%USERPROFILE%\.dsh\onebot-catchup-pending.jsonl`，一行一条）：
//   {"id":"10001","ms":1700000000000,"from":"10000001","text":"在吗"}
//   {"ack":"1025756466"}
//
// ★ 为什么是追加不是改写：写的人（插件）和读/ack 的人（命令行、简报）是两个进程。
//   整份重写的文件两边一撞必丢一边；小行追加是原子的，谁也不覆盖谁。
//   代价是文件只涨不缩（一条约 200 字节，几次断线也就几 KB），补不补都无所谓。
// ★ ack 不等于删除：原文一直留着，只是不再出现在「还没处理」里。

import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'

/** 一次最多看多少条（更早的还在文件里，只是不显示）。 */
export const PENDING_MAX = 40

/** 清单文件路径。DSH_HOME 优先，跟插件那边 dshHome() 一个口径。 */
export function pendingPath() {
  const home = process.env.DSH_HOME || path.join(os.homedir(), '.dsh')
  return path.join(home, 'onebot-catchup-pending.jsonl')
}

function readRows(file) {
  let raw = ''
  try { raw = fs.readFileSync(file, 'utf8') } catch { return [] }
  const out = []
  for (const line of raw.split('\n')) {
    if (line.trim() === '') continue
    try {
      const row = JSON.parse(line)
      if (row && (row.id !== undefined || row.ack !== undefined)) out.push(row)
    } catch { /* 坏行跳过，不因为一行坏了整份读不出来 */ }
  }
  return out
}

/**
 * 还没处理掉的（有 id、没被 ack），**由旧到新**。
 * @param {{file?: string, limit?: number}} [options]
 * @returns {{id: string, ms: number, from: string, text: string}[]}
 */
export function openEntries({ file = pendingPath(), limit = PENDING_MAX } = {}) {
  const rows = readRows(file)
  const acked = new Set()
  for (const row of rows) if (row.ack !== undefined) acked.add(String(row.ack))
  const open = []
  for (const row of rows) {
    if (row.id === undefined) continue
    const id = String(row.id)
    if (acked.has(id)) continue
    open.push({ id, ms: Number(row.ms) || 0, from: String(row.from ?? ''), text: String(row.text ?? '') })
  }
  open.sort((a, b) => a.ms - b.ms)
  return limit > 0 ? open.slice(-limit) : open
}

/** 标记几条处理过了（appends `{"ack": id}`）。重复 ack 无害。返回真正写了几行。 */
export function ackEntries(ids, { file = pendingPath() } = {}) {
  const list = (ids ?? []).map((x) => String(x)).filter((x) => x !== '')
  if (!list.length) return 0
  const acked = new Set()
  for (const row of readRows(file)) if (row.ack !== undefined) acked.add(String(row.ack))
  const lines = []
  for (const id of list) {
    if (acked.has(id)) continue
    acked.add(id)
    lines.push(JSON.stringify({ ack: id }))
  }
  if (!lines.length) return 0
  fs.mkdirSync(path.dirname(file), { recursive: true })
  fs.appendFileSync(file, lines.join('\n') + '\n', 'utf8')
  return lines.length
}

/** 「10-29 08:30」；不是今年的带上年份。 */
export function stamp(ms) {
  const d = new Date(ms)
  if (Number.isNaN(d.getTime())) return '??-?? ??:??'
  const two = (n) => String(n).padStart(2, '0')
  const md = `${two(d.getMonth() + 1)}-${two(d.getDate())}`
  const hm = `${two(d.getHours())}:${two(d.getMinutes())}`
  return d.getFullYear() === new Date().getFullYear() ? `${md} ${hm}` : `${d.getFullYear()}-${md} ${hm}`
}

/**
 * 一行可读文本。`clip` 用来压进简报（正文可以不压，命令行要能看全）。
 */
export function formatEntry(entry, { clip = 0 } = {}) {
  let text = String(entry.text ?? '').replace(/\r?\n/g, ' ⏎ ').trim()
  if (clip > 0 && text.length > clip) text = text.slice(0, clip) + '…'
  return `${stamp(entry.ms)}  ${entry.id}  ${text || '（没有文字，可能是图/语音）'}`
}
