---
date: 2026-07-21
tags: [netdisplay, handoff, relay, go, server]
---

# Relay 中转服务器设计与部署

> **2026-07-22 更新（v1.4 持久配对，已部署上线）**：REGISTER/JOIN 现在接受两种房间键——
> ① `code`（6 位数字，原行为不变）；② `pairHash`（64 位**小写 hex**，即 `hex(SHA256(pairSecret 原始 32 字节))`）。
> pairHash 优先于 code。**pairHash 房间的特殊行为**：不受 5 分钟 TTL 限制（Sender 可无限期待命）；
> 同 hash 重复 REGISTER 会**替换旧连接**（旧的被关闭，断线重连自愈，不会 code_taken）；JOIN 撮合后房间移除，Sender 会话结束后需重新 REGISTER。
> 下文 Go 源码为 v1 原版，最新版以服务器 `/opt/apps/netdisplay-relay/main.go` 为准。

> 部署负责方：Windows 端 Claude（有 15 服务器的部署通道）。Mac 端只需实现 `02-protocol.md` §7 的客户端消息。
> 服务器：15.tokencv.com，监听 **TCP 47700**（直接暴露，不经 nginx；nginx 不擅长长连接裸 TCP 低延迟转发场景，没必要引入）。

## 职责

1. **配对撮合**：Sender 用 RELAY_REGISTER 登记 6 位配对码；Receiver 用 RELAY_JOIN 携码加入；撮合成功向双方发 RELAY_PAIRED。
2. **字节转发**：配对后对两条连接做双向透明转发，不解析内容。

不做的事：不存储任何数据、不解析视频协议、不做用户系统。

## 防护要求（端口暴露公网）

- 未配对连接 30 秒无有效消息即断开。
- 配对码 5 分钟过期、一次性（PAIRED 后立即从表中移除）。
- 同一 IP 的 JOIN 尝试限速：每分钟 10 次，超出返回 `rate_limited` 并断开。
- 每个房间只允许 1 个 sender + 1 个 receiver。
- 转发阶段设置 5 分钟无流量空闲超时。

## 完整实现（Go，单文件）

```go
// netdisplay-relay/main.go
package main

import (
	"encoding/binary"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net"
	"strings"
	"sync"
	"time"
)

const (
	listenAddr     = ":47700"
	maxCtrlPayload = 4096
	unpairedTTL    = 30 * time.Second
	codeTTL        = 5 * time.Minute
	idleTTL        = 5 * time.Minute
	joinPerMinute  = 10

	tRegister = 0x40
	tJoin     = 0x41
	tPaired   = 0x42
	tError    = 0x43
)

type ctrlMsg struct {
	V        int    `json:"v"`
	Role     string `json:"role"`
	Code     string `json:"code"`
	PairHash string `json:"pairHash,omitempty"`
}

type room struct {
	sender  net.Conn
	created time.Time
}

var (
	mu     sync.Mutex
	rooms  = map[string]*room{}
	joinRl = map[string][]time.Time{} // ip -> join timestamps
)

func main() {
	ln, err := net.Listen("tcp", listenAddr)
	if err != nil {
		log.Fatal(err)
	}
	log.Printf("netdisplay-relay listening on %s", listenAddr)
	go janitor()
	for {
		c, err := ln.Accept()
		if err != nil {
			continue
		}
		go handle(c)
	}
}

func janitor() {
	for range time.Tick(30 * time.Second) {
		mu.Lock()
		for code, r := range rooms {
			if time.Since(r.created) > codeTTL {
				r.sender.Close()
				delete(rooms, code)
			}
		}
		cut := time.Now().Add(-time.Minute)
		for ip, ts := range joinRl {
			kept := ts[:0]
			for _, t := range ts {
				if t.After(cut) {
					kept = append(kept, t)
				}
			}
			if len(kept) == 0 {
				delete(joinRl, ip)
			} else {
				joinRl[ip] = kept
			}
		}
		mu.Unlock()
	}
}

func readFrame(c net.Conn) (byte, []byte, error) {
	hdr := make([]byte, 5)
	if _, err := io.ReadFull(c, hdr); err != nil {
		return 0, nil, err
	}
	n := binary.BigEndian.Uint32(hdr[1:])
	if n > maxCtrlPayload {
		return 0, nil, errors.New("payload too large")
	}
	p := make([]byte, n)
	if _, err := io.ReadFull(c, p); err != nil {
		return 0, nil, err
	}
	return hdr[0], p, nil
}

func writeFrame(c net.Conn, t byte, payload []byte) error {
	buf := make([]byte, 5+len(payload))
	buf[0] = t
	binary.BigEndian.PutUint32(buf[1:], uint32(len(payload)))
	copy(buf[5:], payload)
	_, err := c.Write(buf)
	return err
}

func sendErr(c net.Conn, reason string) {
	b, _ := json.Marshal(map[string]string{"reason": reason})
	writeFrame(c, tError, b)
}

func handle(c net.Conn) {
	if tc, ok := c.(*net.TCPConn); ok {
		tc.SetNoDelay(true)
	}
	c.SetReadDeadline(time.Now().Add(unpairedTTL))
	t, p, err := readFrame(c)
	if err != nil {
		c.Close()
		return
	}
	var m ctrlMsg
	if json.Unmarshal(p, &m) != nil || len(m.Code) != 6 {
		sendErr(c, "bad_request")
		c.Close()
		return
	}
	switch t {
	case tRegister:
		mu.Lock()
		if _, exists := rooms[m.Code]; exists {
			mu.Unlock()
			sendErr(c, "code_taken")
			c.Close()
			return
		}
		rooms[m.Code] = &room{sender: c, created: time.Now()}
		mu.Unlock()
		// sender 挂起等待 join；期间延长 deadline 到配对码有效期
		c.SetReadDeadline(time.Now().Add(codeTTL))
	case tJoin:
		ip := c.RemoteAddr().String()
		if i := strings.LastIndex(ip, ":"); i > 0 {
			ip = ip[:i]
		}
		mu.Lock()
		joinRl[ip] = append(joinRl[ip], time.Now())
		recent := 0
		for _, ts := range joinRl[ip] {
			if time.Since(ts) < time.Minute {
				recent++
			}
		}
		if recent > joinPerMinute {
			mu.Unlock()
			sendErr(c, "rate_limited")
			c.Close()
			return
		}
		r, ok := rooms[m.Code]
		if ok {
			delete(rooms, m.Code) // 一次性
		}
		mu.Unlock()
		if !ok {
			sendErr(c, "code_not_found")
			c.Close()
			return
		}
		pair(r.sender, c)
		return
	default:
		sendErr(c, "bad_request")
		c.Close()
	}
}

func pair(sender, receiver net.Conn) {
	ok, _ := json.Marshal(map[string]bool{"ok": true})
	sender.SetReadDeadline(time.Time{})
	if writeFrame(sender, tPaired, ok) != nil || writeFrame(receiver, tPaired, ok) != nil {
		sender.Close()
		receiver.Close()
		return
	}
	log.Printf("paired %s <-> %s", sender.RemoteAddr(), receiver.RemoteAddr())
	done := make(chan struct{}, 2)
	pipe := func(dst, src net.Conn) {
		buf := make([]byte, 256*1024)
		for {
			src.SetReadDeadline(time.Now().Add(idleTTL))
			n, err := src.Read(buf)
			if n > 0 {
				if _, werr := dst.Write(buf[:n]); werr != nil {
					break
				}
			}
			if err != nil {
				break
			}
		}
		done <- struct{}{}
	}
	go pipe(sender, receiver)
	go pipe(receiver, sender)
	<-done
	sender.Close()
	receiver.Close()
	<-done
	log.Printf("session closed")
}
```

## 部署步骤（15 服务器）

```bash
# 本地交叉编译（Windows/Mac 上均可）
GOOS=linux GOARCH=amd64 go build -o netdisplay-relay .

# 上传并安装
scp netdisplay-relay <15服务器>:/usr/local/bin/
```

systemd 单元 `/etc/systemd/system/netdisplay-relay.service`：

```ini
[Unit]
Description=NetDisplay pairing relay
After=network.target

[Service]
ExecStart=/usr/local/bin/netdisplay-relay
Restart=always
RestartSec=3
User=nobody
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
```

```bash
systemctl daemon-reload && systemctl enable --now netdisplay-relay
# 防火墙/安全组放行 TCP 47700（云控制台 + ufw 如有）
```

验证：本地 `nc 15.tokencv.com 47700` 能连上，30 秒被踢（unpairedTTL 生效）。

## 带宽提醒

中转模式视频码率默认 10 Mbps，流量同时经过服务器的下行+上行。确认 15 服务器带宽是否能稳定承载（若只有 5 Mbps 上行，需把中转模式码率降到 4 Mbps 并接受画质下降）。这也是中转模式默认码率远低于直连模式的原因。
