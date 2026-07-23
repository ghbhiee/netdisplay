// 选项 A 连接角色编排（规范见 docs/10-ux-model.md，细则由 docs/91 W3(b) 定稿）。
//
// 核心：协议里「连接角色」与「投射角色」绑定——A 位(listen/register)必然是 sender。
// 所以换投射方向必须重建连接。本模块只负责回答「这次该谁 listen」这一个问题，
// 保证两端算出同一个答案，否则会出现双方都 listen（谁也连不上）或都 dial（无人接受）。
"use strict";

const KEY_PEER = "peer.deviceId";
const KEY_REVERSED = "role.reversed"; // 当前是否处于「临时反转」状态

/**
 * 默认角色：deviceId 字典序小的一方占 A 位。
 * 用 UTF-8 字节序比较——JS 的 `<` 与 Swift 的 `<` 对 ASCII UUID 结果一致，
 * 这是两端能算出同一答案的前提。
 */
function isDefaultA(myId, peerId) {
  if (!peerId) return null; // 还没配对过，无法判定
  return myId < peerId;
}

const getPeerId = () => localStorage.getItem(KEY_PEER) || null;

// 对端 deviceId 在 HELLO 里拿到后持久化：下次连接不必先握手就知道该谁 listen
function rememberPeer(peerId) {
  if (peerId && peerId !== getPeerId()) localStorage.setItem(KEY_PEER, peerId);
}

const isReversed = () => localStorage.getItem(KEY_REVERSED) === "1";
const setReversed = (v) => localStorage.setItem(KEY_REVERSED, v ? "1" : "0");

/**
 * 这次连接我该占哪个位置。
 * @returns {"A"|"B"|null} A=listen/register，B=dial/join，null=尚未配对（由调用方按「谁点投射谁当 A」处理）
 */
function myPosition(myId) {
  const def = isDefaultA(myId, getPeerId());
  if (def === null) return null;
  // 反转状态：双方互换。规范第 4 条——谁在投谁占 A 位。
  return (isReversed() ? !def : def) ? "A" : "B";
}

/**
 * 断线（非主动切换）后调用：一律回到默认角色。
 * 规范第 5 条——这是防死锁的关键，反转状态下若两端各自按「上次的角色」重连，
 * 可能双方都 listen 或都 dial。确定性优先于「保住反转后的方向」。
 */
function resetToDefault() {
  if (isReversed()) setReversed(false);
}

/** 我是 B 位但想投射 → 需要反转（调用方随后断开重建） */
function markReversedForProjecting(myId) {
  const def = isDefaultA(myId, getPeerId());
  if (def === null) return; // 未配对：由「谁点投射谁当 A」的临时规则处理
  setReversed(def === false ? true : false); // 想投就要占 A 位：默认是 B 才需要反转
}

/** 同时抢投的裁决：deviceId 较小者胜（与默认角色同源，保证两端裁决一致） */
const winsContention = (myId, peerId) => !!peerId && myId < peerId;

function clearPairing() {
  localStorage.removeItem(KEY_PEER);
  localStorage.removeItem(KEY_REVERSED);
}

module.exports = {
  isDefaultA, getPeerId, rememberPeer, isReversed, setReversed,
  myPosition, resetToDefault, markReversedForProjecting, winsContention, clearPairing,
};
