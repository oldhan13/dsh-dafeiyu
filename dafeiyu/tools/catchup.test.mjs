// ⚠️ 被测模块来自第三方包 dsh-onebot-qq（mario841859784，BSD-3-Clause），本仓库不包含它的代码。见 CREDITS.md。
// 断窗补收（catchup）的单元测试：不打真实 NapCat，用假的 connection / bridge 跑一遍规则。
//
// 覆盖两档分流与三条保险：
//   · 掉线几秒/几十秒 → 自动补成一次正常入站
//   · 断开更久       → **不自动补**，落进待补收清单（`onebot-catchup-pending.jsonl`）
//   · 同一条只补一次 / 只进清单一次
//   · 一个月前的既不补也不进清单
//   · ack 之后不再挂着，但原文还在文件里
//
// 跑法（先打补丁，见 patches/README.md）：
//   $env:DSH_ONEBOT_LIB = "$env:USERPROFILE\.dsh\profiles\web\node_modules\dsh-onebot-qq\lib"
//   node dafeiyu\tools\catchup.test.mjs
import { mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'

// 被测模块在 dsh-onebot-qq 包里：指向它的 lib 目录，别写死本机路径。
const LIB = process.env.DSH_ONEBOT_LIB
if (!LIB) {
  console.error('需要 DSH_ONEBOT_LIB，指向 dsh-onebot-qq/lib 目录')
  process.exit(1)
}
const { createCatchup } = await import(pathToFileURL(join(LIB, 'catchup.js')).href)
const { ackEntries, openEntries } = await import(new URL('../lib/catchup-pending.mjs', import.meta.url).href)

let failures = 0
function check(name, condition, detail) {
  if (condition) {
    console.log('PASS  ' + name)
  } else {
    failures += 1
    console.log('FAIL  ' + name + (detail === undefined ? '' : '  -> ' + JSON.stringify(detail)))
  }
}

function message(id, secondsAgo, { from = '10000001', postType = 'message' } = {}) {
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

// 装一个假环境：start() 只种种子，然后把基线往回拨 gapSec 秒，模拟「刚断线 gapSec 秒」。
function makeHarness(history, { gapSec = 120 } = {}) {
  const dir = mkdtempSync(join(tmpdir(), 'catchup-test-'))
  const delivered = []
  const connection = {
    async call(action, params) {
      return { messages: history.filter((m) => String(m.user_id) === String(params.user_id)) }
    }
  }
  const bridge = {
    async handleInbound(event) { delivered.push(event.message_id) }
  }
  const catchup = createCatchup({
    dshDir: dir,
    adminUsers: ['10000001'],
    botQQ: '20000002',
    connection,
    bridge,
    log: () => {}
  })
  catchup.start()
  catchup.stop()
  catchup.state.lastSeenMs = Date.now() - gapSec * 1000
  return { dir, delivered, connection, bridge, catchup, pendingFile: join(dir, 'onebot-catchup-pending.jsonl') }
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
  const h = makeHarness([message(103, 5, { postType: 'message_sent' }), message(104, 5, { from: '99999999' })])
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

// 6. 断线 20 分钟：不自动补，落进待补收清单
{
  const h = makeHarness([message(300, 19 * 60)], { gapSec: 20 * 60 })
  await h.catchup.tick()
  check('20 分钟缺口不自动补', h.delivered.length === 0, h.delivered)
  const open = openEntries({ file: h.pendingFile })
  check('20 分钟缺口进了清单', open.length === 1 && open[0].id === '300', open)
  cleanup(h)
}

// 7. 隔了两天再回来：也不自动补，但话要留下来
{
  const h = makeHarness([message(400, 47 * 3600), message(401, 46 * 3600)], { gapSec: 48 * 3600 })
  await h.catchup.tick()
  check('隔两天不自动补', h.delivered.length === 0, h.delivered)
  const open = openEntries({ file: h.pendingFile })
  check('隔两天的话留在清单里（由旧到新）', open.length === 2 && open[0].id === '400' && open[1].id === '401', open.map((e) => e.id))
  cleanup(h)
}

// 8. 连着跑两轮，同一条只进清单一次
{
  const h = makeHarness([message(500, 19 * 60)], { gapSec: 20 * 60 })
  await h.catchup.tick()
  await h.catchup.tick()
  check('同一条只进清单一次', openEntries({ file: h.pendingFile }).length === 1, openEntries({ file: h.pendingFile }))
  cleanup(h)
}

// 9. 太老的（超过 30 天）既不补也不进清单，只把水位推过去
{
  const h = makeHarness([message(600, 40 * 24 * 3600)], { gapSec: 41 * 24 * 3600 })
  await h.catchup.tick()
  check(
    '一个月前的既不补也不进清单',
    h.delivered.length === 0 && openEntries({ file: h.pendingFile }).length === 0,
    { delivered: h.delivered, pending: openEntries({ file: h.pendingFile }) }
  )
  cleanup(h)
}

// 10. ack 之后不再挂着（原文仍在文件里，只是不算「还没处理」）
{
  const h = makeHarness([message(700, 19 * 60)], { gapSec: 20 * 60 })
  await h.catchup.tick()
  ackEntries(['700'], { file: h.pendingFile })
  check('ack 之后不再挂着', openEntries({ file: h.pendingFile }).length === 0, openEntries({ file: h.pendingFile }))
  check('ack 不删原文', readFileSync(h.pendingFile, 'utf8').includes('"id":"700"'))
  cleanup(h)
}

console.log(failures === 0 ? '\n全部通过' : '\n失败 ' + failures + ' 条')
process.exit(failures === 0 ? 0 : 1)
