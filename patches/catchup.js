/**
 * 断窗补收（catch-up）。
 *
 * 背景：QQ 通道是「NapCat 主动拨号 + 宿主进程内监听」。插件层任何一次重载
 * （改 profile 配置、gui 保存设置、整宿主重启）都会让 8643 关停重开，
 * NapCat 要几十秒才重新拨上；这期间他发来的消息既不在 OneBot 的队列里、
 * 也没有人收，直接丢了 —— 表现就是「聊着聊着人不见了」。
 *
 * 做法：每 20 秒问一次 NapCat 的 get_friend_msg_history，把「时间晚于上次
 * 见到的时间、且没处理过」的私聊消息按缺口长短分两档处理：
 *   · 缺口 ≤ AUTO_REPLAY_MS（刚聊着掉了一下）→ 按正常入站流程重新交给 bridge，
 *     于是那一轮会被正常回答；
 *   · 缺口更长（宿主停过、整夜关机）→ **不自动补**，写成一行追加到
 *     `<dsh home>/onebot-catchup-pending.jsonl`，等人来看：那样既不会一条弹一次，
 *     也不会像我换个语境就答岔。看和 ack 由工作区的 `dafeiyu/lib/catchup-pending.mjs` 做。
 *
 * 状态存在 `<dsh home>/.onebot-catchup.json`：
 *   { lastSeenMs: number, lastTickMs: number, handled: { "<message_id>": <epoch ms> } }
 * 第一次运行（没有状态文件）只写种子、不补收 —— 否则一装上就会把历史全replay一遍。
 *
 * 四个保险：
 *   1. 只补私聊、只补 adminUsers 里的人（群聊有 groupPolicy 管，且群里她自己看）；
 *   2. 自动补单次最多 MAX_REPLAY 条，且只补 AUTO_REPLAY_MS 以内的；
 *   3. 处理过的 message_id 记一段时间，避免重复回；
 *   4. 断超过 30 天的既不补也不进清单，只推水位（没人想回一个月前的「在吗」）。
 */
import { appendFileSync, existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'

/** 启动后等这么久再跑第一次（给重连留时间）。 */
const FIRST_TICK_MS = 6000
/** 之后的轮询间隔。 */
const INTERVAL_MS = 20_000
/** 单次最多自动补几条（按时间由旧到新）。 */
const MAX_REPLAY = 10
/**
 * 缺口不超过这么久，就当作「正聊着掉了一下」，自动补成一次正常入站。
 *
 * 2026-10-31 改：原来的规矩是「状态超过 6 小时 ⇒ 直接推进到 now、一条不补」，
 * 本意是防重复回，代价却是把**真断线**期间的话整段丢掉 —— 他 10-29 说的那两句
 * （「你还想要什么功能？」「网络断了让你说不了话我很抱歉」）就是这么没的，
 * 而且丢掉时没有任何痕迹：日志里只写一句 state stale。
 * 现在改成两档：刚掉的自动补；断久了的不自动补，但**写进待补收清单**留给人看。
 */
const AUTO_REPLAY_MS = 15 * 60 * 1000
/** 超过这个岁数的消息不再进清单（没人想回一个月前的「在吗」）。 */
const PENDING_MAX_AGE_MS = 30 * 24 * 60 * 60 * 1000
/** handled 表最多留多少条。 */
const HANDLED_MAX = 128
/** 每次拉多少条历史。 */
const HISTORY_COUNT = 20

/**
 * @param {object} deps
 * @param {string} deps.dshDir          DSH home（存状态文件用）
 * @param {string[]} deps.adminUsers    允许私聊的人
 * @param {string} deps.botQQ           自己的号（把 message_sent 排掉）
 * @param {object} deps.connection      OneBotConnection（用 call()）
 * @param {object} deps.bridge          ChatBridge（用 handleInbound()）
 * @param {(level: string, message: string) => void} [deps.log]
 */
export function createCatchup({ dshDir, adminUsers, botQQ, connection, bridge, log }) {
    const statePath = join(dshDir, '.onebot-catchup.json')
    const logPath = join(dshDir, 'onebot-catchup.log')
    /**
     * 待补收清单：**只追加的 JSONL**，一行一条。
     *   {"id":"10001","ms":1700000000000,"from":"10000001","text":"在吗"}
     *   {"ack":"1025756466"}                       ← 人看过、算了结
     * 为什么不用 state.json 里再开一个数组：那份文件是整份重写的（rename），
     * 而清单会被**另一个进程**（命令行 / 我自己）读和 ack —— 两边同时读改写必丢。
     * 追加写小行是原子的，谁也不覆盖谁。
     */
    const pendingPath = join(dshDir, 'onebot-catchup-pending.jsonl')
    const admins = (adminUsers ?? []).map((x) => String(x)).filter((x) => x !== '' && x !== String(botQQ ?? ''))
    let timer
    let firstTimer
    let running = false
    let state = { lastSeenMs: 0, lastTickMs: 0, handled: {} }

    function write(level, message) {
        const line = new Date().toISOString().replace('T', ' ').slice(0, 19) + '  ' + level + '  ' + message
        try { log?.(level, 'catchup: ' + message) } catch { }
        try {
            mkdirSync(dshDir, { recursive: true })
            appendFileSync(logPath, line + '\n', 'utf8')
        } catch { }
    }

    function load() {
        if (!existsSync(statePath)) {
            state = { lastSeenMs: Date.now(), lastTickMs: Date.now(), handled: {} }
            save()
            write('info', 'first run: seeded lastSeenMs=' + state.lastSeenMs + ' (no replay)')
            return
        }
        try {
            const parsed = JSON.parse(readFileSync(statePath, 'utf8'))
            state = {
                lastSeenMs: Number(parsed?.lastSeenMs) || 0,
                lastTickMs: Number(parsed?.lastTickMs) || 0,
                handled: parsed?.handled && typeof parsed.handled === 'object' ? parsed.handled : {},
            }
            // 2026-10-20 那条守卫：「状态太久 ⇒ 推进到 now、不补」，防的是重复回。
            // 2026-10-31 改窄了 —— 它把真断线整段丢掉了（10-29 那两句），因为断线期间
            // 水位本来就该是旧的。现在只拦它真正要拦的那一种：
            // **轮询一直在跑（lastTickMs 是新的），水位却停在老地方** ⇒ 是 markSeen 那条线坏了，
            // 不是宿主停了。宿主整个停掉时两个时间戳会一起变旧，那正好是要补的情形。
            const gapMs = state.lastSeenMs > 0 ? Date.now() - state.lastSeenMs : 0
            const pollingAlive = state.lastTickMs > 0 && Date.now() - state.lastTickMs < 5 * 60 * 1000
            if (gapMs > AUTO_REPLAY_MS && pollingAlive) {
                write('info', 'watermark stuck (' + Math.round(gapMs / 1000) + 's) while polling was alive: advancing to now, no replay')
                state.lastSeenMs = Date.now()
            } else if (gapMs > AUTO_REPLAY_MS) {
                write('info', 'long gap ' + Math.round(gapMs / 60000) + 'min (host was down): missed messages will be queued for review, not auto-replayed')
            }
        } catch (error) {
            // 状态坏了：宁可从头种一次，也不要 replay 一堆旧消息
            state = { lastSeenMs: Date.now(), lastTickMs: Date.now(), handled: {} }
            write('warn', 'state unreadable (' + String(error) + '): reseeded')
        }
        save()
    }

    function save() {
        try {
            mkdirSync(dshDir, { recursive: true })
            const tmp = statePath + '.tmp'
            writeFileSync(tmp, JSON.stringify(state), 'utf8')
            renameSync(tmp, statePath)
        } catch (error) {
            write('warn', 'state write failed: ' + String(error))
        }
    }

    function pruneHandled() {
        const keys = Object.keys(state.handled)
        if (keys.length <= HANDLED_MAX) return
        keys
            .sort((a, b) => Number(state.handled[a]) - Number(state.handled[b]))
            .slice(0, keys.length - HANDLED_MAX)
            .forEach((k) => { delete state.handled[k] })
    }

    /** 把待补收清单读成 [{id, ms, from, text} | {ack}] —— 坏行直接跳过，不因为一行坏了整份都读不出来。 */
    function readPending() {
        const rows = []
        let raw = ''
        try { raw = readFileSync(pendingPath, 'utf8') } catch { return rows }
        for (const line of raw.split('\n')) {
            if (line.trim() === '') continue
            try {
                const row = JSON.parse(line)
                if (row && (row.id !== undefined || row.ack !== undefined)) rows.push(row)
            } catch { }
        }
        return rows
    }

    /**
     * 读清单这件事**不放在这里** —— 读和 ack 由工作区的
     * `dafeiyu/lib/catchup-pending.mjs` 做（命令行和简报共用那一份）。
     * 这一层只负责「发现漏了就追加一行」，插件被升级覆盖时损失最小。
     */

    /**
     * 追加进清单（已记过的 id 不重复记）。
     * @returns 真正新增了几条；**写盘失败返回 -1**（调用方据此决定要不要推水位 ——
     *   写失败还把水位推过去，那几条就永久没了）。
     */
    function addPending(items) {
        if (!items.length) return 0
        const recorded = new Set()
        for (const row of readPending()) {
            if (row.id !== undefined) recorded.add(String(row.id))
            if (row.ack !== undefined) recorded.add(String(row.ack))
        }
        const lines = []
        for (const item of items) {
            const id = String(item.id ?? '')
            if (id === '') continue
            if (recorded.has(id)) continue
            recorded.add(id)
            lines.push(JSON.stringify({ id, ms: Number(item.ms) || 0, from: String(item.from ?? ''), text: String(item.text ?? '').slice(0, 4000) }))
        }
        if (!lines.length) return 0
        try {
            mkdirSync(dshDir, { recursive: true })
            appendFileSync(pendingPath, lines.join('\n') + '\n', 'utf8')
        } catch (error) {
            write('warn', 'pending append failed: ' + String(error))
            return -1
        }
        return lines.length
    }

    /** 正常入站也要推进 lastSeen，否则重连后会把刚聊过的再补一遍。 */
    function markSeen(timeMs) {
        const ms = Number(timeMs)
        if (!Number.isFinite(ms) || ms <= 0) return
        if (ms > state.lastSeenMs) {
            state.lastSeenMs = ms
            save()
        }
    }

    function toEvent(message) {
        // 历史接口返回的形状已经和入站事件一致（post_type=message），补上保险字段。
        return { ...message, post_type: 'message' }
    }

    async function tick() {
        if (running) return { replayed: 0, skipped: 'busy' }
        running = true
        let replayed = 0
        let queued = 0
        try {
            const now = Date.now()
            const misses = []
            for (const userId of admins) {
                let data
                try {
                    data = await connection.call('get_friend_msg_history', { user_id: userId, count: HISTORY_COUNT })
                } catch (error) {
                    // 没连上就安静跳过，下一轮再来
                    continue
                }
                const messages = Array.isArray(data?.messages) ? data.messages : []
                for (const message of messages) {
                    if (message?.post_type !== 'message') continue
                    if (String(message.user_id ?? '') === String(botQQ ?? '')) continue
                    if (String(message.user_id ?? '') !== userId) continue
                    const ms = Number(message.time) * 1000
                    if (!Number.isFinite(ms) || ms <= 0) continue
                    const id = String(message.message_id ?? '')
                    if (id === '') continue
                    if (state.handled[id] !== undefined) continue
                    if (ms <= state.lastSeenMs) continue
                    misses.push({ ms, id, message })
                }
            }
            misses.sort((a, b) => a.ms - b.ms)
            // 两档分流：刚掉的（AUTO_REPLAY_MS 内）补成一次正常入站，让她照常回答；
            // 断久了的不自动补 —— 那样会一条弹一次、而且我可能早就换了个语境。
            // 写进清单，等她自己看、自己合成一句话回答。
            const fresh = []
            const stale = []
            for (const item of misses) {
                if (now - item.ms <= AUTO_REPLAY_MS) fresh.push(item)
                else if (now - item.ms <= PENDING_MAX_AGE_MS) stale.push(item)
                // 更老的：不补也不进清单，但要推水位，免得每次都重新算一遍
                else markSeen(item.ms)
            }
            const queuedCount = addPending(stale.map((item) => ({
                id: item.id,
                ms: item.ms,
                from: String(item.message?.user_id ?? ''),
                text: String(item.message?.raw_message ?? ''),
            })))
            queued = queuedCount > 0 ? queuedCount : 0
            if (queuedCount > 0) {
                write('info', 'queued ' + queuedCount + ' missed message(s) for review (gap ' +
                    Math.round((now - state.lastSeenMs) / 60000) + 'min, not auto-replayed)')
            }
            // ⚠ 写清单失败（-1）时**不能推水位** —— 推了那几条就永久没了，下一轮也不会再挑出来。
            if (queuedCount >= 0) for (const item of stale) markSeen(item.ms)
            else write('warn', 'pending write failed: watermark NOT advanced, ' + stale.length + ' message(s) will be retried next tick')
            const todo = fresh.slice(-MAX_REPLAY)
            for (const item of todo) {
                try {
                    await bridge.handleInbound(toEvent(item.message))
                    state.handled[item.id] = item.ms
                    markSeen(item.ms)
                    replayed += 1
                    write('info', 'replayed message ' + item.id + ' at ' + new Date(item.ms).toISOString())
                } catch (error) {
                    write('warn', 'replay failed for ' + item.id + ': ' + String(error))
                }
            }
            pruneHandled()
            // 记下「这一轮轮询真的跑过」。load() 拿它分辨「宿主停了」和「markSeen 坏了」。
            // 每分钟最多落一次盘，没必要每 20 秒写一遍。
            if (now - state.lastTickMs >= 60_000) {
                state.lastTickMs = now
                save()
            }
            if (replayed > 0 || queued > 0) save()
        } finally {
            running = false
        }
        return { replayed, queued }
    }

    function start() {
        load()
        firstTimer = setTimeout(() => { void tick() }, FIRST_TICK_MS)
        timer = setInterval(() => { void tick() }, INTERVAL_MS)
        if (typeof firstTimer.unref === 'function') firstTimer.unref()
        if (typeof timer.unref === 'function') timer.unref()
        write('info', 'started (admins=' + admins.join(',') + ', every ' + INTERVAL_MS / 1000 + 's)')
    }

    function stop() {
        if (firstTimer) clearTimeout(firstTimer)
        if (timer) clearInterval(timer)
        firstTimer = undefined
        timer = undefined
        write('info', 'stopped')
    }

    return {
        start,
        stop,
        tick,
        markSeen,
        pendingPath,
        get state() { return state },
    }
}
