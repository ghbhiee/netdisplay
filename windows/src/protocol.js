// NetDisplay 协议 v1 帧编解码（SOT: OneDrive/ob/netdisplay-handoff/02-protocol.md）
"use strict";

const T = {
  HELLO: 0x01,
  HELLO_ACK: 0x02,
  VIDEO_FRAME: 0x10,
  REQUEST_KEYFRAME: 0x11,
  VIDEO_CONFIG: 0x12,
  PROJECTION_STATE: 0x13,
  INPUT_EVENT: 0x20,
  CONTROL: 0x21,
  PING: 0x30,
  PONG: 0x31,
  BYE: 0x3f,
  RELAY_REGISTER: 0x40,
  RELAY_JOIN: 0x41,
  RELAY_PAIRED: 0x42,
  RELAY_ERROR: 0x43,
  // docs/11：服务器撮合的双向配对。两端各发 ANNOUNCE，relay 见到同 pairHash、
  // 不同 deviceId 的两个就给双方回 CONFIRMED（含对端 deviceId+name）并记下这对。
  PAIR_ANNOUNCE: 0x44, // client→relay {v, pairHash, deviceId, name, token}
  PAIR_CONFIRMED: 0x45, // relay→client {peerDeviceId, peerName}
  // 02 §3.8：连通性探测。47800 常驻响应器读到 PROBE 就原样回 PROBE_ACK（回显 8 字节）。
  // 直连判据 = 收到 PROBE_ACK 且回显匹配，**不是** TCP connect 成功（TUN 会骗）。
  PROBE: 0x46, // 探测方→响应器，payload = 8 字节随机数
  PROBE_ACK: 0x47, // 响应器→探测方，原样回显那 8 字节
  // docs/11 §5：presence。app 开着时对配对设备维持一条 presence 连接向 relay 报状态，
  // relay 转给对端。用户要的「对方在不在线、接收服务开没开、能不能投」靠它。
  PRESENCE: 0x48, // client→relay {v, pairHash, deviceId, name, state, token}
  PEER_PRESENCE: 0x49, // relay→client {peerDeviceId, peerName, peerState}
};

const MAX_PAYLOAD = 16 * 1024 * 1024;

function buildFrame(type, payload) {
  const p =
    payload == null
      ? Buffer.alloc(0)
      : Buffer.isBuffer(payload)
        ? payload
        : Buffer.from(typeof payload === "string" ? payload : JSON.stringify(payload), "utf8");
  const b = Buffer.alloc(5 + p.length);
  b[0] = type;
  b.writeUInt32BE(p.length, 1);
  p.copy(b, 5);
  return b;
}

// 流式帧解析器：feed(chunk) → onFrame(type, payload) 回调
class FrameParser {
  constructor(onFrame) {
    this.onFrame = onFrame;
    this.buf = Buffer.alloc(0);
  }
  feed(chunk) {
    this.buf = this.buf.length === 0 ? chunk : Buffer.concat([this.buf, chunk]);
    while (this.buf.length >= 5) {
      const len = this.buf.readUInt32BE(1);
      if (len > MAX_PAYLOAD) throw new Error("payload too large: " + len);
      if (this.buf.length < 5 + len) break;
      const type = this.buf[0];
      const payload = this.buf.subarray(5, 5 + len);
      this.buf = this.buf.subarray(5 + len);
      this.onFrame(type, payload);
    }
  }
}

// VIDEO_FRAME 载荷: [pts_us u64 BE][flags u8][Annex-B]
function parseVideoPayload(p) {
  return {
    ptsUs: p.readBigUInt64BE(0),
    keyframe: (p[8] & 1) === 1,
    data: p.subarray(9),
  };
}

function buildVideoPayload(ptsUs, keyframe, annexb) {
  const head = Buffer.alloc(9);
  head.writeBigUInt64BE(BigInt(ptsUs), 0);
  head[8] = keyframe ? 1 : 0;
  return Buffer.concat([head, annexb]);
}

module.exports = { T, MAX_PAYLOAD, buildFrame, FrameParser, parseVideoPayload, buildVideoPayload };
