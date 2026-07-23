// 角色编排的单元测试。这是两端一致性的基础：算错一次就连不上，
// 而且跨机才暴露（本地单端测不出「双方都 listen」）。所以在这里穷举验证。
"use strict";

// 用内存 stub 顶掉 localStorage（本模块在 renderer 里跑，测试在 node 里跑）
const store = new Map();
global.localStorage = {
  getItem: (k) => (store.has(k) ? store.get(k) : null),
  setItem: (k, v) => store.set(k, String(v)),
  removeItem: (k) => store.delete(k),
};
const R = require("../src/role");

let pass = 0, fail = 0;
const check = (name, got, want) => {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  console.log(`${ok ? "  ✓" : "  ✗"} ${name}${ok ? "" : `  期望 ${JSON.stringify(want)}，实得 ${JSON.stringify(got)}`}`);
  ok ? pass++ : fail++;
};

// 模拟两端各自独立计算（各有自己的 localStorage）
function sideOf(myId, peerId, reversed) {
  store.clear();
  store.set("peer.deviceId", peerId);
  store.set("role.reversed", reversed ? "1" : "0");
  return R.myPosition(myId);
}

const SMALL = "11111111-aaaa-4000-8000-000000000001";
const LARGE = "99999999-zzzz-4000-8000-000000000009";

console.log("【默认角色：deviceId 小的占 A 位】");
check("小 id 端 → A", sideOf(SMALL, LARGE, false), "A");
check("大 id 端 → B", sideOf(LARGE, SMALL, false), "B");

console.log("【两端必须互补，绝不能同为 A 或同为 B】");
for (const [a, b] of [[SMALL, LARGE], [LARGE, SMALL], ["aaa", "bbb"], ["b", "a"]]) {
  const pa = sideOf(a, b, false), pb = sideOf(b, a, false);
  check(`(${a.slice(0, 4)},${b.slice(0, 4)}) 互补`, pa !== pb, true);
}

console.log("【反转后仍互补（换投射方向的场景）】");
for (const [a, b] of [[SMALL, LARGE], [LARGE, SMALL]]) {
  const pa = sideOf(a, b, true), pb = sideOf(b, a, true);
  check(`(${a.slice(0, 4)},${b.slice(0, 4)}) 反转后互补`, pa !== pb, true);
}
check("反转把 A 变 B", sideOf(SMALL, LARGE, true), "B");
check("反转把 B 变 A", sideOf(LARGE, SMALL, true), "A");

console.log("【未配对时无法判定，交给「谁点投射谁当 A」的临时规则】");
store.clear();
check("无 peerId → null", R.myPosition(SMALL), null);

console.log("【断线一律回默认角色（规范第 5 条，防死锁）】");
store.clear();
store.set("peer.deviceId", LARGE);
R.setReversed(true);
check("重置前是反转", R.isReversed(), true);
R.resetToDefault();
check("重置后回默认", R.isReversed(), false);
check("重置后 小id 端回到 A", R.myPosition(SMALL), "A");

console.log("【B 位想投 → 标记反转后应占 A 位】");
store.clear();
store.set("peer.deviceId", SMALL); // 我是 LARGE，默认 B 位
check("标记前是 B", R.myPosition(LARGE), "B");
R.markReversedForProjecting(LARGE);
check("标记后变 A", R.myPosition(LARGE), "A");

console.log("【A 位想投 → 本就是 A，标记后仍是 A（不该反转）】");
store.clear();
store.set("peer.deviceId", LARGE); // 我是 SMALL，默认 A 位
R.markReversedForProjecting(SMALL);
check("仍是 A", R.myPosition(SMALL), "A");

console.log("【同时抢投：小 id 胜，且两端裁决一致】");
check("小 id 胜", R.winsContention(SMALL, LARGE), true);
check("大 id 败", R.winsContention(LARGE, SMALL), false);
check("裁决互斥", R.winsContention(SMALL, LARGE) !== R.winsContention(LARGE, SMALL), true);

console.log(`\n${fail === 0 ? "RESULT: PASS" : "RESULT: FAIL"}  (${pass} 通过, ${fail} 失败)`);
process.exit(fail === 0 ? 0 : 1);
