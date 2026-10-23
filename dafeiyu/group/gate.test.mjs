// 群里「该不该说话」那道的回归测试。
// 跑法：node gate.test.mjs     （不启服务、不连 NapCat）
//
// 口径变更史：
//   2026-10-19 · 只回 @ 她的人，和 @ 之后接着说的那场话（代码里卡两道闸）
//   2026-10-21 夜 · 主人重新定：「没必要点名，只要是和你相关的，或者说和你在聊的话题有关的内容就可以回」
//                   ⇒ 代码撤掉「必须被点名」「必须是在跟她说」这两道，
//                     只留结构性检查，**相关性交给模型判**；反刷屏仍由配额兜（每小时 4 句 / 间隔 10 分钟）。
//   同日 · 「几条集中在一起回，而不是每一条一条一条的回」⇒ parseDirective 允许多行 REPLY。
import assert from 'node:assert/strict';
import { replyGate, parseDirective } from './watch.mjs';

const stranger = { qq: '999000111', text: '我我我 算我一个', addressed: false, named: false };
const callName = { qq: '999000111', text: '大肥鱼你说呢', addressed: false, named: true };
const myself = { qq: '20002', text: '我在', addressed: false, named: false, self: true };
const atAll = { qq: '999000111', text: '今晚有人开黑吗', addressed: false, atAll: true, named: false };
const replyElse = { qq: '999000111', text: '对，就是这样', addressed: false, replyToOther: true, replyToNick: '淆晨', named: false };
const emptyOne = { qq: '999000111', text: '   ', addressed: false, named: false };

const cases = [
  ['没人点她名，但旁人在说话 → 放行（相关性由模型判）', { inThread: false, fresh: [stranger], withWhom: [] }, true],
  ['有人在聊别人的私聊 → 也放行（模型判该不该插）', { inThread: true, fresh: [replyElse], withWhom: ['10001'] }, true],
  ['@全体 → 放行（模型知道那不是叫她）', { inThread: false, fresh: [atAll], withWhom: [] }, true],
  ['点了她的名 → 放行', { inThread: true, fresh: [callName], withWhom: [] }, true],
  ['只有她自己刚说的话 → 不许自说自话', { inThread: true, fresh: [myself], withWhom: [] }, false],
  ['全是空壳 → 不许说', { inThread: true, fresh: [emptyOne], withWhom: [] }, false],
  ['她自己 + 旁人都说了 → 放行', { inThread: false, fresh: [myself, stranger], withWhom: [] }, true]
];

let bad = 0;
for (const [name, input, want] of cases) {
  const got = replyGate(input).ok;
  const ok = got === want;
  if (!ok) bad++;
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}  (期望 ${want}，实际 ${got})`);
}

// ---- 指令解析：多行 REPLY = 几条集中在一起 ----
const parsed = [
  ['单行 REPLY', 'REPLY: 一句', 'REPLY: 一句'],
  ['多行 REPLY 收成同一段', 'REPLY: 第一句\n第二句\n- 第三句\nNOTE: 记一下', 'REPLY: 第一句\n第二句\n第三句'],
  ['REPLY 里夹推理标签', '</think>\nREPLY: 好', 'REPLY: 好'],
  ['SILENT', 'SILENT', 'SILENT'],
  ['SILENT 带尾巴', 'SILENT 这轮不插嘴', 'SILENT'],
  ['NOTE 两行折成一行', 'NOTE: 群主换了\n下周开新档', 'NOTE: 群主换了 下周开新档'],
  ['没有指令 → 原样第一行', '嗯 好像是这样', '嗯 好像是这样']
];
for (const [name, input, want] of parsed) {
  const got = parseDirective(input);
  const ok = got === want;
  if (!ok) bad++;
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}  (期望 ${JSON.stringify(want)}，实际 ${JSON.stringify(got)})`);
}

// 多行 REPLY 交给下游时，换行必须保住（下游按 [\s\S] 抓）
const multiline = parseDirective('REPLY: 一\n二');
assert.equal(multiline.split('\n').length, 2);

console.log(bad === 0 ? '全部通过' : `${bad} 条不符`);
process.exit(bad === 0 ? 0 : 1);
