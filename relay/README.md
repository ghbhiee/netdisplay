# Relay（中转服务器）

Go 单文件、零依赖。只做**配对撮合 + 透明字节转发**，不解析视频协议。规范见 `../docs/05-relay-server.md` 与 `../docs/02-protocol.md` §7。

- 房间键：6 位数字 `code`（一次性，5 分钟过期）或 `pairHash`（v1.4 持久配对：64 位小写 hex，不过期、同 hash 重复注册替换旧连接）。
- v1.7 抖动保护：pairHash 房间的「后来者顶替」是断线自愈所必需，但两个都活着的发送端会**互相顶替**——各自的「断线后重注册」逻辑正好互相踩，形成静默的无限互踢（双方日志都只显示注册成功）。现在同一房间 15 秒内被顶替超过 3 次即判定抖动，拒绝并回 `RELAY_ERROR{"reason":"room_occupied"}`。**客户端收到它应停止自动重连**。所有连接开启 TCP keepalive(30s)，半开连接不再永久占房间。
- v1.5 token 认证：设置环境变量 `NETDISPLAY_RELAY_TOKEN` 即启用——REGISTER/JOIN 必须携带匹配的 `token`，否则回 `RELAY_ERROR{"reason":"unauthorized"}`。未设置则放行（私网用）。
- 防护：未配对连接 30s 踢出、JOIN 限速（同 IP 10 次/分钟）、转发空闲 5 分钟超时。

## 部署（Debian/Ubuntu + systemd）

```bash
go build -o /usr/local/bin/netdisplay-relay main.go
cp netdisplay-relay.service /etc/systemd/system/

# 配 token（不要写进仓库/单元文件，用 drop-in）：
mkdir -p /etc/systemd/system/netdisplay-relay.service.d
printf '[Service]\nEnvironment=NETDISPLAY_RELAY_TOKEN=<你的token>\n' \
  > /etc/systemd/system/netdisplay-relay.service.d/token.conf
chmod 600 /etc/systemd/system/netdisplay-relay.service.d/token.conf

systemctl daemon-reload
systemctl enable --now netdisplay-relay
journalctl -u netdisplay-relay -f   # 应显示 "token auth ENABLED"
```

防火墙/安全组放行 TCP 47700。验证：`nc <host> 47700` 能连上、30 秒被踢。

## 验收测试（tools/）

```bash
export NETDISPLAY_RELAY_TOKEN=<token>       # 服务器启用鉴权时
node tools/test-token.js    [host]          # v1.5：无 token 拒 / 带 token 通
node tools/test-pairhash.js [host]          # v1.4：pairHash 撮合、替换注册、code 回归
node tools/test-relay.js    [host] [port]   # 基础：配对、双向转发、错误码
node tools/test-flapping.js [host]          # v1.7：互踢抖动应被 room_occupied 打断
```

