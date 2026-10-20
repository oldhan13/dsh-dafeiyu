// 群里「该不该说话」那两道闸的回归测试。
// 跑法：node gate.test.mjs     （不启服务、不连 NapCat）
//
// 规矩是 2026-10-19 主人定的：只回 @ 她的人，和 @ 之后接着说的那场话。
// 2026-10-19 夜加的两条：引用回复算叫她；「在回别人的话」一律不接（@全体也不算）。
import assert from 'node:assert/strict';
import { replyGate } from './watch.mjs';

const owner = { qq: '10001', text: '看得到吗', addressed: true, named: false };
const ownerFollow = { qq: '10001', text: '刚问你那个事', addressed: false, named: false };
const stranger = { qq: '999000111', text: '我我我 算我一个', addressed: false, named: false };
const callName = { qq: '999000111', text: '大肥鱼你说呢', addressed: false, named: true };
const myself = { qq: '20002', text: '我在', addressed: false, named: false, self: true };
const atAll = { qq: '999000111', text: '今晚有人开黑吗', addressed: false, atAll: true, named: false };
const replyMe = { qq: '10001', text: '你刚那句什么意思', addressed: false, replyToMe: true, named: false };
const replyElse = { qq: '999000111', text: '对，就是这样', addressed: false, replyToOther: true, replyToNick: '淆晨', named: false };

const cases = [
  ['没人点过她 → 不许说', { inThread: false, fresh: [stranger], withWhom: ['10001'] }, false],
  ['@ 过她的人在接着说 → 可以说', { inThread: true, fresh: [ownerFollow], withWhom: ['10001'] }, true],
  ['@ 之后旁人在聊 → 不许说', { inThread: true, fresh: [stranger], withWhom: ['10001'] }, false],
  ['没 @ 但点了名 → 可以说', { inThread: true, fresh: [callName], withWhom: ['10001'] }, true],
  ['有人重新 @ 她 → 可以说（这时主会话也会回，交给配额兜）', { inThread: true, fresh: [owner], withWhom: ['10001'] }, true],
  ['@ 过但她已经过了 15 分钟 → 不许说', { inThread: false, fresh: [ownerFollow], withWhom: ['10001'] }, false],
  ['只有她自己刚说的话 → 不许自说自话', { inThread: true, fresh: [myself], withWhom: ['10001'] }, false],
  ['引用回她的话 → 可以说', { inThread: true, fresh: [replyMe], withWhom: ['10001'] }, true],
  ['旁人在回另一个人的话 → 不许说', { inThread: true, fresh: [replyElse], withWhom: ['10001'] }, false],
  ['一屋子人互相回话（没有一句冲她）→ 不许说', { inThread: true, fresh: [replyElse, replyElse, stranger], withWhom: ['10001'] }, false],
  ['@全体 → 不算叫她，不许说', { inThread: true, fresh: [atAll], withWhom: ['10001'] }, false],
  ['她没开口时没人 @、只见旁人互回 → 不许说', { inThread: false, fresh: [replyElse], withWhom: [] }, false]
];

let bad = 0;
for (const [name, input, want] of cases) {
  const got = replyGate(input).ok;
  const ok = got === want;
  if (!ok) bad++;
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}  (期望 ${want}，实际 ${got})`);
}
console.log(bad === 0 ? '全部通过' : `${bad} 条不符`);
process.exit(bad === 0 ? 0 : 1);
