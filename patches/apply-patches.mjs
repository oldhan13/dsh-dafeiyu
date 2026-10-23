#!/usr/bin/env node
/**
 * dsh-dafeiyu 本地补丁 —— 把大肥鱼要的两处改动打到 `dsh-onebot-qq` 里。
 *
 *   1. poke-inbound   戳一戳（notice/notify/poke）翻成一条 "[戳一戳]" 消息，走正常入站管线
 *   2. split-private  私聊里一段多行回复，按行拆成几条发（一句一个气泡）
 *
 * 为什么要打补丁：这两件事插件本身不做，而 npm 包一升级就会被覆盖，
 * 所以放在这里，装的时候自动重打。补丁是**整段锚点替换**，不是 diff，
 * 认不出锚点就报错退出（不硬改），宁可不打也不要改坏。
 *
 * 用法：
 *   node patches/apply-patches.mjs                  # 自动找 ~/.dsh/profiles/web
 *   node patches/apply-patches.mjs --profile web
 *   node patches/apply-patches.mjs --dir <dsh-onebot-qq/lib 的绝对路径>
 *   node patches/apply-patches.mjs --check          # 只报告，不写文件
 *
 * 退出码：0 = 全部已就位（打过或刚打上）；1 = 有补丁打不上（会打印原因）；2 = 找不到插件。
 */
import { readFileSync, writeFileSync, copyFileSync, existsSync, statSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { homedir } from 'node:os';
import { execFileSync } from 'node:child_process';

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

/** @type {{id:string, file:string, marker:string, ops:{find:string, replace:string}[]}[]} */
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
];

function parseArgs(argv) {
    const out = { profile: 'web', dir: null, check: false };
    for (let i = 0; i < argv.length; i += 1) {
        const a = argv[i];
        if (a === '--check') out.check = true;
        else if (a === '--profile') out.profile = argv[++i];
        else if (a === '--dir') out.dir = argv[++i];
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
        const file = join(lib, patch.file);
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
        for (const op of patch.ops) {
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
