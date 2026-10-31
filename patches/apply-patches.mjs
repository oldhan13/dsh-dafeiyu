#!/usr/bin/env node
/**
 * dsh-dafeiyu 本地补丁 —— 把大肥鱼要的几处改动打到 `dsh-onebot-qq` 里。
 *
 *   1. poke-inbound        戳一戳（notice/notify/poke）翻成一条 "[戳一戳]" 消息，走正常入站管线
 *   2. split-private       私聊里一段多行回复，按行拆成几条发（一句一个气泡）
 *   3. mirror-group-send   插件发进群的话也补记一行到 group/raw.jsonl，watch 才看得见
 *   4. emoji-reaction      白名单放行 set_msg_emoji_like（贴在消息底下的表情回应）
 *   5. catchup-module      新增 `lib/catchup.js`（断线补收模块，**这个文件是我们自己写的**，
 *                          上游 0.9.3 的包里没有它，所以是整份复制过去）
 *   6. catchup-wiring      在 `index.js` 里把 catchup 接上（建实例 → 正常入站也推水位 → start/stop）
 *   7. catchup-reminder    在 `prompt.js` 里每轮提一句「有 N 条断线期间没送到的」
 *
 * 为什么要打补丁：这几件事插件本身不做，而 npm 包一升级就会被覆盖，
 * 所以放在这里，装的时候自动重打。补丁是**整段锚点替换**，不是 diff，
 * 认不出锚点就报错退出（不硬改），宁可不打也不要改坏。
 *
 * 用法：
 *   node patches/apply-patches.mjs                  # 自动找 ~/.dsh/profiles/web
 *   node patches/apply-patches.mjs --profile web
 *   node patches/apply-patches.mjs --dir <dsh-onebot-qq/lib 的绝对路径>
 *   node patches/apply-patches.mjs --check          # 只报告，不写文件
 *   node patches/apply-patches.mjs --only catchup-wiring,catchup-reminder
 *
 * 退出码：0 = 全部已就位（打过或刚打上）；1 = 有补丁打不上（会打印原因）；2 = 找不到插件。
 */
import { readFileSync, writeFileSync, copyFileSync, existsSync, statSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { homedir } from 'node:os';
import { execFileSync } from 'node:child_process';

/** 这个脚本自己所在目录（`patches/`）—— `catchup.js` 就放在这儿。 */
const PATCHES_DIR = dirname(fileURLToPath(import.meta.url));

// ── 补丁 1：poke 入站 ────────────────────────────────────────────────
const POKE_MARKER = 'Local patch (dafeiyu 2026-10-20)';
const POKE_ANCHOR = "            // notice / request events are intentionally ignored (v1).";
const POKE_BLOCK = [
    '            // Local patch (dafeiyu 2026-10-20): 戳一戳（poke）不是 message 而是',
    '            // notice/notify/poke，v1 把所有 notice 都丢了 ⇒ 她根本感觉不到被戳。',
    '            // 现在：一条戳向本账号的 poke 会被翻成一条普通文字消息 "[戳一戳]"',
    '            // 走正常入站管线（去重/限流/回合调度都照旧）。',
    '            // 只翻「目标是本账号」的那种：群里别人互戳、以及自己戳自己都丢掉。',
    "            if (event.post_type === 'notice'",
    "                && event.notice_type === 'notify'",
    "                && event.sub_type === 'poke') {",
    "                const self = String(event.self_id ?? this.selfId ?? '');",
    "                const poker = String(event.user_id ?? '');",
    "                const targetId = event.target_id === undefined || event.target_id === null ? '' : String(event.target_id);",
    '                const rawGroup = event.group_id;',
    '                const inGroup = rawGroup !== undefined && rawGroup !== null',
    "                    && String(rawGroup) !== '' && String(rawGroup) !== '0';",
    "                const aimedAtMe = targetId === '' || (self !== '' && targetId === self);",
    "                if (poker !== '' && (self === '' || poker !== self) && aimedAtMe) {",
    '                    const pokeEvent = {',
    "                        post_type: 'message',",
    "                        message_type: inGroup ? 'group' : 'private',",
    '                        self_id: event.self_id,',
    '                        user_id: poker,',
    '                        group_id: inGroup ? rawGroup : undefined,',
    "                        message_id: 'poke-' + Date.now().toString(36) + '-' + Math.random().toString(36).slice(2, 8),",
    "                        message: [{ type: 'text', data: { text: '[戳一戳]' } }],",
    "                        raw_message: '[戳一戳]',",
    '                        sender: event.sender ?? {},',
    '                        time: event.time,',
    '                    };',
    "                    this.log('info', 'poke -> turn: ' + (inGroup ? 'group ' + String(rawGroup) : 'private ' + poker));",
    '                    try {',
    '                        this.onMessage(pokeEvent);',
    '                    }',
    '                    catch (error) {',
    "                        this.log('error', 'onMessage (poke) handler failed: ' + describeError(error) + errorStack(error));",
    '                    }',
    '                }',
    '                else {',
    "                    this.log('debug', 'poke ignored (self or not aimed at this account): ' + poker + ' -> ' + targetId);",
    '                }',
    '                return;',
    '            }',
].join('\n');

// ── 补丁 2：私聊分句 ─────────────────────────────────────────────────
const SPLIT_MARKER = 'splitPrivateLines';
const SPLIT_HELPER_ANCHOR = [
    "export const ACTION_AUDIT_FILE = 'qq-actions.log';",
    '/**',
    ' * The outbound pipeline.',
].join('\n');
const SPLIT_HELPER_BLOCK = [
    "export const ACTION_AUDIT_FILE = 'qq-actions.log';",
    '/** 2026-10-20 · 分句：私聊里一段回答按行拆成几条，别全挤进一个气泡。',
    ' *  只在“像说话”的时候拆：2–8 行、每行不超过 160 字；长文/代码块照样整段发。 */',
    'const SPLIT_LINES_MAX = 8;',
    'const SPLIT_LINE_CHARS_MAX = 160;',
    'const SPLIT_GAP_MS = 320;',
    'function splitPrivateLines(chatId, text) {',
    "    if (splitChatId(chatId).kind !== 'private')",
    '        return [text];',
    "    const lines = text.split(/\\n+/).map((l) => l.trim()).filter((l) => l !== '');",
    '    if (lines.length < 2 || lines.length > SPLIT_LINES_MAX)',
    '        return [text];',
    '    if (lines.some((l) => l.length > SPLIT_LINE_CHARS_MAX))',
    '        return [text];',
    '    return lines;',
    '}',
    'const sleep = (ms) => new Promise((r) => setTimeout(r, ms));',
    '/**',
    ' * The outbound pipeline.',
].join('\n');

const SPLIT_SEND_ANCHOR = [
    '                const plain = stripMarkdown(body);',
    "                if (plain !== '') {",
    "                    const id = await this.sendMsg(chatId, [{ type: 'text', data: { text: plain } }], options);",
    '                    if (id !== undefined)',
    '                        ids.push(id);',
    '                }',
].join('\n');
const SPLIT_SEND_BLOCK = [
    '                const plain = stripMarkdown(body);',
    "                if (plain !== '') {",
    '                    const parts = splitPrivateLines(chatId, plain);',
    '                    for (let i = 0; i < parts.length; i += 1) {',
    '                        const opts = i === 0 ? options : { ...options, replyTo: undefined };',
    "                        const id = await this.sendMsg(chatId, [{ type: 'text', data: { text: parts[i] } }], opts);",
    '                        if (id !== undefined)',
    '                            ids.push(id);',
    '                        if (i < parts.length - 1)',
    '                            await sleep(SPLIT_GAP_MS);',
    '                    }',
    '                }',
].join('\n');

// ── 补丁 3：群消息镜像进 raw.jsonl（2026-10-23）─────────────────────
// 为什么：群里有两条嘴 —— watch 自己发的它记得（sendGroup 发完就补一行 self:true），
// 而主会话经插件发进群的话，raw.jsonl 里没有、watch 的窗口也没有；这台机器的 NapCat
// 又不推 message_sent（5444 条里 self 一直是 0）。于是 watch 看见「有人 @ 过她、却没看见
// 她的回话」，过几分钟可能再答一遍。把插件发出的群消息也补记一行，字段与 watch 完全对齐。
const MIRROR_MARKER = 'mirrorGroupSend';
const MIRROR_HELPER_ANCHOR = [
    '/** Max queued final replies per chat; the oldest is dropped beyond this (M1-B6). */',
    'const PENDING_SEND_MAX = 20;',
].join('\n');
const MIRROR_HELPER_BLOCK = [
    '/** Max queued final replies per chat; the oldest is dropped beyond this (M1-B6). */',
    'const PENDING_SEND_MAX = 20;',
    '/** Local patch (dafeiyu 2026-10-23) · 群消息镜像（mirrorGroupSend）。',
    ' *  群里有两条嘴：watch 发完会自己往 raw.jsonl 补一行 self:true，所以它记得自己说过什么；',
    ' *  而主会话经插件发进群的话，raw.jsonl 里没有、watch 的窗口也没有，NapCat 也不推 message_sent。',
    ' *  ⇒ watch 看见「有人 @ 过她、却没看见她的回话」，过几分钟可能再答一遍。',
    ' *  这里把插件发出去的群消息也补记一行，字段与 watch 的 sendGroup() 一一对齐',
    ' *  （preloadWindow 直接读这几列：ts/qq/nick/text/self/gid/mid + 那几个布尔）。',
    ' *  边界：只对群生效；目录不存在（不是她那台机器）静默跳过；失败绝不影响发送。',
    ' *  局限：t2i 文字图卡片那边靠调用方传 mirrorText 把原文带过来，否则只能记 [图片]。 */',
    'const MIRROR_RAW_FILE = process.env.DAFEIYU_GROUP_RAW',
    "    || join(process.env.USERPROFILE || process.env.HOME || '', 'Documents', 'deepseek-harness', 'default-workspace', 'dafeiyu', 'group', 'raw.jsonl');",
    'function mirrorTextOf(segments) {',
    '    const parts = [];',
    '    for (const seg of Array.isArray(segments) ? segments : []) {',
    "        if (seg?.type === 'text')",
    "            parts.push(String(seg.data?.text ?? ''));",
    "        else if (seg?.type === 'image')",
    "            parts.push('[图片]');",
    "        else if (seg?.type === 'at')",
    "            parts.push('@' + String(seg.data?.qq ?? ''));",
    "        else if (seg?.type === 'face')",
    "            parts.push('[表情]');",
    '    }',
    "    return parts.join('').trim();",
    '}',
    'async function mirrorGroupSend(chatId, segments, messageId, selfId, overrideText) {',
    '    try {',
    '        const ref = splitChatId(chatId);',
    "        if (ref.kind !== 'group')",
    '            return;',
    '        const text = String(overrideText ?? mirrorTextOf(segments)).trim();',
    "        if (text === '')",
    '            return;',
    '        const line = JSON.stringify({',
    "            ts: Date.now(), qq: String(selfId ?? ''), nick: '汐', text: text.slice(0, 500),",
    '            addressed: false, atAll: false, named: false,',
    "            replyToId: '', replyToMe: false, replyToOther: false, replyToNick: '', replyUnknown: false,",
    "            self: true, gid: String(ref.target), mid: String(messageId ?? ''),",
    "        }) + '\\n';",
    "        await appendFile(MIRROR_RAW_FILE, line, 'utf8');",
    '    }',
    '    catch {',
    '        /* 镜像只是给 watch 看，失败不影响发送 */',
    '    }',
    '}',
].join('\n');

const MIRROR_CARD_ANCHOR = [
    "                        const id = await this.sendMsg(chatId, [{ type: 'image', data: { file: b64 } }], options);",
].join('\n');
const MIRROR_CARD_BLOCK = [
    '                        // Local patch (dafeiyu 2026-10-23): 文字图卡片发的是 [图片]，原文要一起带过去，',
    '                        // 不然 raw.jsonl 里只剩 [图片]，watch 不知道那句话说过没有。',
    "                        const id = await this.sendMsg(chatId, [{ type: 'image', data: { file: b64 } }], { ...options, mirrorText: body });",
].join('\n');

const MIRROR_SEND_ANCHOR = [
    "        const data = await this.ctx.call('send_msg', params, chatId);",
    '        return data.message_id !== undefined ? String(data.message_id) : undefined;',
].join('\n');
const MIRROR_SEND_BLOCK = [
    "        const data = await this.ctx.call('send_msg', params, chatId);",
    '        const messageId = data.message_id !== undefined ? String(data.message_id) : undefined;',
    '        // Local patch (dafeiyu 2026-10-23): 群消息也镜像一份给 watch（见 mirrorGroupSend 注释）',
    '        // ⚠ 参数求值也必须兜住：这里一旦抛，发送就失败了 —— 镜像只是锦上添花，绝不能反向伤到发送。',
    '        try {',
    '            await mirrorGroupSend(chatId, segments, messageId, this.ctx.selfId() || this.ctx.config.botQQ, options === null || options === void 0 ? void 0 : options.mirrorText);',
    '        }',
    '        catch {',
    '            /* 镜像失败绝不影响发送 */',
    '        }',
    '        return messageId;',
].join('\n');

// ── 补丁 4：表情回应进白名单（2026-10-26）────────────────────────────
// 为什么：`qq_napcat_api` 只放行 NAPCAT_API_WHITELIST 里的 action，而「贴在消息底下的小 emoji」
// （set_msg_emoji_like）不在里面 —— 想贴只能绕开插件直连 NapCat 的 HTTP，等于把端口和 token
// 搬到别处写死。放进白名单，走已有的 qq_napcat_api，参数 {message_id, emoji_id, set}。
// 锚点选白名单**末尾三项 + 收尾的 ]**：比只锚一行稳，上游要加新 action 多半加在这一行前后。
const EMOJI_MARKER = 'set_msg_emoji_like';
const EMOJI_ANCHOR = [
    "    'ocr_image',",
    "    'get_ai_characters',",
    "    'send_group_ai_record',",
    '];',
].join('\n');
const EMOJI_BLOCK = [
    "    'ocr_image',",
    "    'get_ai_characters',",
    "    'send_group_ai_record',",
    '    // Local patch (dafeiyu 2026-10-26): 消息表情回应 —— 贴在消息底部的小 emoji，不额外发一条。',
    '    // 走 qq_napcat_api：{ message_id, emoji_id: "128077", set: true }。',
    "    'set_msg_emoji_like',",
    '];',
].join('\n');

// ── 补丁 5/6/7：断线补收（2026-10-31）────────────────────────────────
// 三件事分开登记，因为它们改的是三条不同的路：
//   5 只是**新增一个文件**（`lib/catchup.js`，我们自己写的，上游包里没有）；
//   6 在 index.js 里把它接上（少了这一步，模块在磁盘上但没有任何调用点 —— 那种状态以前真的存在过，
//     注释写着「重载那几十秒的私聊会被补回来」，实际从来没发生过）；
//   7 在 prompt.js 里每轮提一句「有 N 条还没处理」—— 少了这句，收进了清单也没人看得见。
//
// 背景（2026-10-31 查明的根因）：上游那版 catchup 有一条守卫「水位超过 6 小时 ⇒ 直接推进到 now、
// 一条都不补」，理由是「怕把早就回过的旧对话重放一遍」。但水位是每一条正常入站都会推进的，
// 它变旧**只可能因为宿主停了** —— 于是真断线期间的话被整段吞掉，而且只留一行 `state stale` 日志。
// 现在三档分流：≤15 分钟自动补 / 15 分钟~30 天**只进清单、不自动补** / 更久只推水位。
const CATCHUP_MARKER = 'onebot-catchup-pending.jsonl';

const CATCHUP_WIRE_DECL_ANCHOR = [
    'let InjectChannel;',
    'let redactSnapshot;',
].join('\n');
const CATCHUP_WIRE_DECL_BLOCK = [
    'let InjectChannel;',
    'let Catchup;',
    'let redactSnapshot;',
].join('\n');

const CATCHUP_WIRE_IMPORT_ANCHOR = [
    "    ({ InjectChannel } = await import('./inject.js'));",
    "    ({ redactSnapshot } = await import('./health.js'));",
].join('\n');
const CATCHUP_WIRE_IMPORT_BLOCK = [
    "    ({ InjectChannel } = await import('./inject.js'));",
    "    ({ createCatchup: Catchup } = await import('./catchup.js'));",
    "    ({ redactSnapshot } = await import('./health.js'));",
].join('\n');

const CATCHUP_WIRE_CREATE_ANCHOR = [
    '        configSnapshot: () => redactSnapshot(config),',
    '        log,',
    '    });',
].join('\n');
const CATCHUP_WIRE_CREATE_BLOCK = [
    '        configSnapshot: () => redactSnapshot(config),',
    '        log,',
    '    });',
    '    // Local patch (dafeiyu 2026-10-31) · 断线补收接线。',
    '    // ⚠ 接上它必须同时把「正常入站」也推进水位，否则 tick 会把刚聊过的消息再补一遍（同一条回两次）。',
    '    //   所以下面覆盖 onMessage：先 markSeen，再交给 bridge。',
    '    const catchup = Catchup === undefined ? undefined : Catchup({',
    '        dshDir: dshHome(),',
    '        adminUsers: policy.adminUsers,',
    '        botQQ: config.botQQ,',
    '        connection,',
    '        bridge,',
    '        log,',
    '    });',
    '    if (catchup !== undefined) {',
    '        connection.onMessage = (event) => {',
    '            try {',
    '                const ms = Number(event?.time) * 1000;',
    '                if (Number.isFinite(ms) && ms > 0)',
    '                    catchup.markSeen(ms);',
    '            }',
    '            catch { }',
    '            void bridge.handleInbound(event);',
    '        };',
    '    }',
].join('\n');

const CATCHUP_WIRE_LIFECYCLE_ANCHOR = [
    '        injectChannel?.start();',
    '        // QQ 平台说明与 qq_* 工具现按会话 agent 注入（见 ChatBridge.installChannelScope）',
    '        return async () => {',
    '            await injectChannel?.stop();',
].join('\n');
const CATCHUP_WIRE_LIFECYCLE_BLOCK = [
    '        injectChannel?.start();',
    '        catchup?.start();',
    '        // QQ 平台说明与 qq_* 工具现按会话 agent 注入（见 ChatBridge.installChannelScope）',
    '        return async () => {',
    '            catchup?.stop();',
    '            await injectChannel?.stop();',
].join('\n');

const CATCHUP_REMINDER_HELPER_ANCHOR = [
    ' * @module dsh-onebot/prompt',
    ' */',
    '/**',
    ' * Build the platform-guidance section text.',
].join('\n');
const CATCHUP_REMINDER_HELPER_BLOCK = [
    ' * @module dsh-onebot/prompt',
    ' */',
    "import { readFileSync } from 'node:fs'",
    "import { homedir } from 'node:os'",
    "import { join } from 'node:path'",
    '',
    '/** Local patch (dafeiyu 2026-10-31) · 断线期间没送到的私聊还有几条没处理。',
    ' *',
    ' * 为什么要在**系统提示**里提一句：那份清单只落在 `~/.dsh/` 里，没有任何东西会',
    ' * 主动把它推进上下文 —— 开场简报三十分钟才重生成一次，而人回来后的第一条消息',
    ' * 往往就落在那三十分钟的窗口里。不提这一句，这个补收等于白做。',
    ' * 读不到 / 读坏了就当 0，绝不因为这一句让整轮失败。',
    ' */',
    'function unreadCatchupCount() {',
    "    let raw = ''",
    '    try {',
    "        raw = readFileSync(join(process.env.DSH_HOME || join(homedir(), '.dsh'), 'onebot-catchup-pending.jsonl'), 'utf8')",
    '    } catch {',
    '        return 0',
    '    }',
    '    const recorded = new Set()',
    '    const acked = new Set()',
    "    for (const line of raw.split('\\n')) {",
    "        if (line.trim() === '') continue",
    '        try {',
    '            const row = JSON.parse(line)',
    '            if (row?.id !== undefined) recorded.add(String(row.id))',
    '            if (row?.ack !== undefined) acked.add(String(row.ack))',
    '        } catch { }',
    '    }',
    '    let count = 0',
    '    for (const id of recorded) if (!acked.has(id)) count += 1',
    '    return count',
    '}',
    '',
    '/**',
    ' * Build the platform-guidance section text.',
].join('\n');

const CATCHUP_REMINDER_LINE_ANCHOR = [
    "    text += '- 斜杠命令由插件拦截（/new /stop /model /workspace /preset /session /status /retry /id /ver /ocr /mode /plan /permission /goal /help，仅管理员，发 /help 查看说明）；你收到其他以 / 开头的内容通常是用户想让模型处理的话题，正常回答即可。\\n';",
    '    return text;',
].join('\n');
const CATCHUP_REMINDER_LINE_BLOCK = [
    "    text += '- 斜杠命令由插件拦截（/new /stop /model /workspace /preset /session /status /retry /id /ver /ocr /mode /plan /permission /goal /help，仅管理员，发 /help 查看说明）；你收到其他以 / 开头的内容通常是用户想让模型处理的话题，正常回答即可。\\n';",
    '    const unread = unreadCatchupCount();',
    '    if (unread > 0) {',
    "        text += '- ⚠ 有 ' + unread + ' 条「断线期间没送到」的私聊（他说了，但从来没进过你的上下文）。先跑 `node dafeiyu/tools/catchup-pending.mjs` 看原文，该合成就合成一句答，答完 `--done <id>` 销掉；不销会一直挂着。\\n';",
    '    }',
    '    return text;',
].join('\n');

/** @type {{id:string, file:string, marker:string, install?:string, ops?:{find:string, replace:string}[]}[]} */
const PATCHES = [
    {
        id: 'poke-inbound',
        file: 'connection.js',
        marker: POKE_MARKER,
        ops: [{ find: POKE_ANCHOR, replace: POKE_BLOCK + '\n' + POKE_ANCHOR }],
    },
    {
        id: 'split-private-replies',
        file: 'outbound.js',
        marker: SPLIT_MARKER,
        ops: [
            { find: SPLIT_HELPER_ANCHOR, replace: SPLIT_HELPER_BLOCK },
            { find: SPLIT_SEND_ANCHOR, replace: SPLIT_SEND_BLOCK },
        ],
    },
    {
        id: 'mirror-group-send',
        file: 'outbound.js',
        marker: MIRROR_MARKER,
        ops: [
            { find: MIRROR_HELPER_ANCHOR, replace: MIRROR_HELPER_BLOCK },
            { find: MIRROR_CARD_ANCHOR, replace: MIRROR_CARD_BLOCK },
            { find: MIRROR_SEND_ANCHOR, replace: MIRROR_SEND_BLOCK },
        ],
    },
    {
        id: 'emoji-reaction',
        file: 'tools.js',
        marker: EMOJI_MARKER,
        ops: [{ find: EMOJI_ANCHOR, replace: EMOJI_BLOCK }],
    },
    {
        // 只做一件事：把 patches/catchup.js 复制成 <lib>/catchup.js。
        // 这个模块是我们自己写的（上游 0.9.3 的包里没有它），所以整份复制，不是打补丁。
        id: 'catchup-module',
        file: 'catchup.js',
        marker: CATCHUP_MARKER,
        install: 'catchup.js',
    },
    {
        id: 'catchup-wiring',
        file: 'index.js',
        marker: 'createCatchup: Catchup',
        ops: [
            { find: CATCHUP_WIRE_DECL_ANCHOR, replace: CATCHUP_WIRE_DECL_BLOCK },
            { find: CATCHUP_WIRE_IMPORT_ANCHOR, replace: CATCHUP_WIRE_IMPORT_BLOCK },
            { find: CATCHUP_WIRE_CREATE_ANCHOR, replace: CATCHUP_WIRE_CREATE_BLOCK },
            { find: CATCHUP_WIRE_LIFECYCLE_ANCHOR, replace: CATCHUP_WIRE_LIFECYCLE_BLOCK },
        ],
    },
    {
        id: 'catchup-reminder',
        file: 'prompt.js',
        marker: 'unreadCatchupCount',
        ops: [
            { find: CATCHUP_REMINDER_HELPER_ANCHOR, replace: CATCHUP_REMINDER_HELPER_BLOCK },
            { find: CATCHUP_REMINDER_LINE_ANCHOR, replace: CATCHUP_REMINDER_LINE_BLOCK },
        ],
    },
];

function parseArgs(argv) {
    const out = { profile: 'web', dir: null, check: false, only: null };
    for (let i = 0; i < argv.length; i += 1) {
        const a = argv[i];
        if (a === '--check') out.check = true;
        else if (a === '--profile') out.profile = argv[++i];
        else if (a === '--dir') out.dir = argv[++i];
        else if (a === '--only') out.only = String(argv[++i] ?? '').split(',').map((s) => s.trim()).filter((s) => s !== '');
        else if (a === '--help' || a === '-h') out.help = true;
    }
    return out;
}

function resolveLibDir(args) {
    if (args.dir) return args.dir;
    return join(homedir(), '.dsh', 'profiles', args.profile, 'node_modules', 'dsh-onebot-qq', 'lib');
}

function syntaxOk(file) {
    try {
        execFileSync(process.execPath, ['--check', file], { stdio: 'pipe' });
        return true;
    } catch {
        return false;
    }
}

function main() {
    const args = parseArgs(process.argv.slice(2));
    if (args.help) {
        console.log('用法：node patches/apply-patches.mjs [--profile web] [--dir <lib 目录>] [--check]');
        process.exit(0);
    }

    const lib = resolveLibDir(args);
    if (!existsSync(lib) || !statSync(lib).isDirectory()) {
        console.error(`✗ 找不到 dsh-onebot-qq 的 lib 目录：${lib}`);
        console.error('  先装插件（install.ps1 -WithQQ），或用 --dir 指过去。');
        process.exit(2);
    }

    console.log(`目标目录：${lib}`);
    let failed = 0;

    for (const patch of PATCHES) {
        if (args.only && !args.only.includes(patch.id)) continue;
        const file = join(lib, patch.file);

        // 新增文件型补丁：整份复制过去（source 在 patches/ 里，是我们自己的代码）。
        if (patch.install) {
            const source = join(PATCHES_DIR, patch.install);
            if (!existsSync(source)) {
                console.error(`✗ ${patch.id}：patches/${patch.install} 不存在`);
                failed += 1;
                continue;
            }
            if (existsSync(file) && readFileSync(file, 'utf8').includes(patch.marker)) {
                console.log(`· ${patch.id}：已经打过（跳过）`);
                continue;
            }
            if (args.check) {
                console.log(`· ${patch.id}：可以装（未写入，--check 模式）`);
                continue;
            }
            try {
                copyFileSync(source, file);
            } catch (error) {
                console.error(`✗ ${patch.id}：复制失败（${String(error)}）`);
                failed += 1;
                continue;
            }
            if (!syntaxOk(file)) {
                console.error(`✗ ${patch.id}：装上后语法不过，请检查 patches/${patch.install}`);
                failed += 1;
                continue;
            }
            console.log(`+ ${patch.id}：已装 ${patch.file}`);
            continue;
        }

        if (!existsSync(file)) {
            console.error(`✗ ${patch.id}：没有 ${patch.file}`);
            failed += 1;
            continue;
        }
        const before = readFileSync(file, 'utf8');
        if (before.includes(patch.marker)) {
            console.log(`· ${patch.id}：已经打过（跳过）`);
            continue;
        }
        let after = before;
        let ok = true;
        for (const op of patch.ops ?? []) {
            if (!after.includes(op.find)) {
                console.error(`✗ ${patch.id}：找不到锚点（插件版本可能变了）`);
                console.error('  锚点开头：' + JSON.stringify(op.find.split('\n')[0]));
                ok = false;
                break;
            }
            after = after.split(op.find).join(op.replace);
        }
        if (!ok) {
            failed += 1;
            continue;
        }
        if (args.check) {
            console.log(`· ${patch.id}：可以打（未写入，--check 模式）`);
            continue;
        }
        const backup = `${file}.orig-${Date.now()}`;
        copyFileSync(file, backup);
        writeFileSync(file, after, 'utf8');
        if (!syntaxOk(file)) {
            copyFileSync(backup, file);
            console.error(`✗ ${patch.id}：打完语法不过，已还原（备份留在 ${backup}）`);
            failed += 1;
            continue;
        }
        console.log(`+ ${patch.id}：已打上（备份 ${backup}）`);
    }

    console.log('');
    console.log(failed === 0 ? '✓ 补丁全部就位' : `! 有 ${failed} 个补丁没打上`);
    console.log('  改完要重启宿主才会加载：关掉 dsh web 再起来（插件模块有缓存）。');
    process.exit(failed === 0 ? 0 : 1);
}

main();
