// group-peek.mjs —— 「群里刚才在聊什么」：她自己翻一眼用。
//
// 出现的理由（2026-10-23 他说的）：「群里没 @ 她的时候，她也想看得见——不回，就想知道你们在聊什么」。
// 开场简报（memory/brief.md）每 30 分钟带一节最近的；这个脚本是**想看更细、更新的时候手动翻**。
//
//   node dafeiyu/tools/group-peek.mjs                 最近 60 分钟，最多 25 条
//   node dafeiyu/tools/group-peek.mjs -m 180 -n 40    看三小时、四十条
//   node dafeiyu/tools/group-peek.mjs -g 1109761217   只看一个群
//   node dafeiyu/tools/group-peek.mjs --all           不限时间（只取文件尾巴 512KB）
//   node dafeiyu/tools/group-peek.mjs --json          给别的脚本吃
//
// ⚠️ 看见 ≠ 要接话：这只是「知道」，要不要开口仍按 AGENTS.md §五·三。
// 这是只读的，不发消息、不动 state。

import { tailMessages, format, ensureNames, readNames } from '../lib/group-chat.mjs';

function arg(name, def) {
  const i = process.argv.indexOf(name);
  if (i < 0) return def;
  const v = process.argv[i + 1];
  return v === undefined || v.startsWith('-') ? def : v;
}
const has = name => process.argv.includes(name);

const minutes = has('--all') ? 0 : Number(arg('-m', 60)) || 60;
const limit = Number(arg('-n', 25)) || 25;
const gid = String(arg('-g', '') || '');
const asJson = has('--json');

// 群名缓存过期（或没有）就顺手拉一次；拉不到就用群号，不影响输出
const names = has('--names') ? await ensureNames({ maxAgeMs: 0 }) : (Object.keys(readNames()).length ? readNames() : await ensureNames());

const msgs = tailMessages({ minutes, limit, gid });

if (asJson) {
  console.log(JSON.stringify(msgs.map(m => ({ ...m, groupName: names[String(m.gid)] || String(m.gid) })), null, 2));
} else {
  const span = minutes > 0 ? `最近 ${minutes} 分钟` : '文件里能翻到的';
  const where = gid ? `${names[gid] || gid} 群` : '各个群';
  if (!msgs.length) {
    console.log(`${span}，${where}没人说话`);
  } else {
    console.log(`${span}的${where}消息（${msgs.length} 条，最下面最新）`);
    for (const m of msgs) console.log(format(m, { names, clip: 110 }));
    console.log('（看得见不等于要接话。想看得更久：-m 180；只看一个群：-g <群号>）');
  }
}
