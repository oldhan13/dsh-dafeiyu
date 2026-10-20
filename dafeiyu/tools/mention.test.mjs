// 群里「这是在跟我说话吗」的判定测试 —— 覆盖 analyzeMention 的六档 + 兼容层。
// 跑法：node dafeiyu/tools/mention.test.mjs
// 被测模块在 dsh-onebot-qq 包里，用环境变量指向它的 lib 目录：
//   PowerShell:  $env:DSH_ONEBOT_LIB = "$env:USERPROFILE\.dsh\profiles\web\node_modules\dsh-onebot-qq\lib"
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'

const LIB = process.env.DSH_ONEBOT_LIB
if (!LIB) {
  console.error('需要 DSH_ONEBOT_LIB，指向 dsh-onebot-qq/lib 目录')
  process.exit(1)
}
const { analyzeMention, detectMention } = await import(pathToFileURL(join(LIB, 'cq.js')).href)

const BOT = '20002'
const OTHER = '2905475882'
const NAMES = ['大肥鱼', '大肥魚', '小鲸鱼', '小鲸魚', '肥鱼', '鲸鱼娘']

// 模拟 message_id → 作者（真的实现里这张表由 inbound 的 recentSenders 提供）
const authors = {
  'm-me': { userId: BOT, nick: '大肥鱼' },
  'm-other': { userId: OTHER, nick: '淆晨' },
}
const resolveReply = (id) => authors[id]

let pass = 0
let fail = 0
function eq(name, got, want) {
  if (got === want) { pass += 1; console.log('  ok   ' + name + '  → ' + got) }
  else { fail += 1; console.log('  FAIL ' + name + '  got=' + got + ' want=' + want) }
}

const seg = (type, data) => ({ type, data })
const run = (segments, raw) => analyzeMention(segments, raw ?? '', BOT, BOT, { names: NAMES, resolveReply })

console.log('\n[直接 @]')
eq('@我', run([seg('at', { qq: BOT })]).level, 'direct')
eq('@别人', run([seg('at', { qq: OTHER })]).level, 'none')
eq('@全体', run([seg('at', { qq: 'all' })]).level, 'broadcast')
eq('@我+@别人', run([seg('at', { qq: OTHER }), seg('at', { qq: BOT })]).level, 'direct')

console.log('\n[引用回复]')
eq('引用我的话（查得到作者）', run([seg('reply', { id: 'm-me' })]).level, 'reply_me')
eq('引用别人的话（查得到作者）', run([seg('reply', { id: 'm-other' })]).level, 'reply_other')
eq('引用别人的话 + 点了我的名', run([seg('reply', { id: 'm-other' }), seg('text', { text: '大肥鱼你怎么看' })]).level, 'named')
eq('引用别人 + @我', run([seg('reply', { id: 'm-other' }), seg('at', { qq: BOT })]).level, 'direct')
const unknownReply = run([seg('reply', { id: 'm-gone' }), seg('text', { text: '你说呢' })])
eq('引用一条查不到作者的话', unknownReply.level, 'none')
eq('…并且标了 replyUnknown', unknownReply.replyUnknown, true)
eq('reply 段自带 qq=我', analyzeMention([seg('reply', { id: 'x', qq: BOT })], '', BOT, BOT, { names: NAMES }).level, 'reply_me')
eq('reply 段自带 qq=别人', analyzeMention([seg('reply', { id: 'x', qq: OTHER })], '', BOT, BOT, { names: NAMES }).level, 'reply_other')

console.log('\n[点名]')
eq('正文里有大肥鱼', run([seg('text', { text: '大肥鱼在吗' })]).level, 'named')
eq('正文里有小鲸鱼', run([seg('text', { text: '小鲸鱼你说' })]).level, 'named')
eq('正文里只有肥鱼两个字', run([seg('text', { text: '肥鱼' })]).level, 'named')
eq('闲聊没提到', run([seg('text', { text: '今天食堂真难吃' })]).level, 'none')

console.log('\n[CQ 串兜底（没有段数组的场合）]')
eq('CQ: at 我', analyzeMention(undefined, '[CQ:at,qq=' + BOT + '] hi', BOT, BOT, { names: NAMES }).level, 'direct')
eq('CQ: at all', analyzeMention(undefined, '[CQ:at,qq=all] hi', BOT, BOT, { names: NAMES }).level, 'broadcast')
eq('CQ: 引用我', analyzeMention(undefined, '[CQ:reply,id=m-me] hi', BOT, BOT, { names: NAMES, resolveReply }).level, 'reply_me')
eq('CQ: 引用别人', analyzeMention(undefined, '[CQ:reply,id=m-other] hi', BOT, BOT, { names: NAMES, resolveReply }).level, 'reply_other')
eq('CQ: 点名', analyzeMention(undefined, '大肥鱼你看', BOT, BOT, { names: NAMES }).level, 'named')

console.log('\n[兼容层 detectMention]')
eq('direct → true', detectMention([seg('at', { qq: BOT })], '', BOT, BOT, { names: NAMES }), true)
eq('broadcast → true', detectMention([seg('at', { qq: 'all' })], '', BOT, BOT, { names: NAMES }), true)
eq('named → true', detectMention([seg('text', { text: '小鲸鱼' })], '', BOT, BOT, { names: NAMES }), true)
eq('reply_other → false', detectMention([seg('reply', { id: 'm-other' })], '', BOT, BOT, { names: NAMES, resolveReply }), false)
eq('闲聊 → false', detectMention([seg('text', { text: '哈哈' })], '', BOT, BOT, { names: NAMES }), false)
eq('不知道机器人号 + @all → false', detectMention([seg('at', { qq: 'all' })], '', '', '', { names: NAMES }), false)

console.log('\n结果：' + pass + ' 过 / ' + fail + ' 败')
process.exit(fail === 0 ? 0 : 1)
