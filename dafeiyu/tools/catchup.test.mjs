// ⚠️ 被测模块来自第三方包 dsh-onebot-qq（mario841859784，BSD-3-Clause），本仓库不包含它的代码。见 CREDITS.md。
// 断窗补收的单元测试：不打真实 NapCat，用假的 connection / bridge 跑一遍规则。
import { mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'

// 被测模块在 dsh-onebot-qq 包里：指向它的 lib 目录，别写死本机路径。
//   PowerShell:  $env:DSH_ONEBOT_LIB = "$env:USERPROFILE\.dsh\profiles\web\node_modules\dsh-onebot-qq\lib"
const LIB = process.env.DSH_ONEBOT_LIB
if (!LIB) {
  console.error('需要 DSH_ONEBOT_LIB，指向 dsh-onebot-qq/lib 目录')
  process.exit(1)
}
const { createCatchup } = await import(pathToFileURL(join(LIB, 'catchup.js')).href)

let failures = 0
function check(name, condition, detail) {
  if (condition) {
    console.log('PASS  ' + name)
  } else {
    failures += 1
    console.log('FAIL  ' + name + (detail === undefined ? '' : '  -> ' + JSON.stringify(detail)))
  }
}

function message(id, secondsAgo, { from = '10001', postType = 'message' } = {}) {
  const time = Math.floor((Date.now() - secondsAgo * 1000) / 1000)
  return {
    post_type: postType,
    message_type: 'private',
    user_id: Number(from),
    time,
    message_id: Number(id),
    raw_message: 'msg ' + id,
    message: [{ type: 'text', data: { text: 'msg ' + id } }],
    sender: { user_id: Number(from), nickname: 'x' }
  }
}

// 装一个假环境：start() 只种种子，然后把基线往回拨两分钟，模拟「刚断线两分钟」。
function makeHarness(history) {
  const dir = mkdtempSync(join(tmpdir(), 'catchup-test-'))
  const delivered = []
  const connection = {
    async call(action, params) {
      return { messages: history.filter((m) => String(m.user_id) === String(params.user_id)) }
    }
  }
  const bridge = {
    async handleInbound(event) {
      delivered.push(event.message_id)
    }
  }
  const catchup = createCatchup({
    dshDir: dir,
    adminUsers: ['10001'],
    botQQ: '20002',
    connection,
    bridge,
    log: () => {}
  })
  catchup.start()
  catchup.stop()
  catchup.state.lastSeenMs = Date.now() - 120000
  return { dir, delivered, connection, bridge, catchup }
}

function cleanup(h) {
  rmSync(h.dir, { recursive: true, force: true })
}

// 1. 第一次运行只种种子（状态文件里有 lastSeenMs），不 replay 历史
{
  const h = makeHarness([message(101, 300)])
  const seeded = JSON.parse(readFileSync(join(h.dir, '.onebot-catchup.json'), 'utf8'))
  check('首次运行写入种子', seeded.lastSeenMs > 0, seeded)
  await h.catchup.tick()
  check('比基线旧的消息不补', h.delivered.length === 0, h.delivered)
  cleanup(h)
}

// 2. 断窗里发来的新消息会被补一次，且只补一次
{
  const h = makeHarness([message(102, 5)])
  await h.catchup.tick()
  check('断窗消息被补上', h.delivered.length === 1 && h.delivered[0] === 102, h.delivered)
  await h.catchup.tick()
  check('同一条不会被补两次', h.delivered.length === 1, h.delivered)
  cleanup(h)
}

// 3. 自己发的（message_sent）和别人的消息都不补
{
  const h = makeHarness([message(103, 5, { postType: 'message_sent' }), message(104, 5, { from: '2905475882' })])
  await h.catchup.tick()
  check('message_sent 与陌生人都不补', h.delivered.length === 0, h.delivered)
  cleanup(h)
}

// 4. 正常入站推进 lastSeen 之后，同一条不会被当成断窗消息
{
  const live = message(105, 3)
  const h = makeHarness([live])
  h.catchup.markSeen(live.time * 1000)
  await h.catchup.tick()
  check('正常收到过的消息不重复补', h.delivered.length === 0, h.delivered)
  cleanup(h)
}

// 5. 一次最多补 10 条，且按时间由旧到新
{
  const many = []
  for (let i = 0; i < 25; i += 1) many.push(message(200 + i, 60 - i))
  const h = makeHarness(many)
  await h.catchup.tick()
  check('单次上限 10 条', h.delivered.length === 10, h.delivered.length)
  check('按时间由旧到新', h.delivered[0] < h.delivered[h.delivered.length - 1], h.delivered)
  cleanup(h)
}

console.log(failures === 0 ? '\n全部通过' : '\n失败 ' + failures + ' 条')
process.exit(failures === 0 ? 0 : 1)
