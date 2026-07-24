// netdisplay-relay: pairing rendezvous + transparent byte relay.
// Spec: OneDrive/ob/netdisplay-handoff/05-relay-server.md + 02-protocol.md §7
package main

import (
	"crypto/subtle"
	"encoding/binary"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net"
	"os"
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
	// v1.12: 双向配对撮合（docs/11）——配对时两端各发 PAIR_ANNOUNCE，relay 见到
	// 同房间不同 deviceId 的两个 announce 就给双方发 PAIR_CONFIRMED 并记录关系。
	tPairAnnounce  = 0x44
	tPairConfirmed = 0x45

	announceTTL = 2 * time.Minute // 等对方输码的最长时间
)

type ctrlMsg struct {
	V        int    `json:"v"`
	Role     string `json:"role"`
	Code     string `json:"code"`
	PairHash string `json:"pairHash,omitempty"`
	Token    string `json:"token,omitempty"` // v1.5 公网鉴权
	DeviceId string `json:"deviceId,omitempty"`
	Name     string `json:"name,omitempty"`
}

// A client waiting (via PAIR_ANNOUNCE) for a peer to announce the same room.
type pendingAnnounce struct {
	conn     net.Conn
	deviceId string
	name     string
	at       time.Time
}

var (
	pendingMu sync.Mutex
	pending   = map[string][]*pendingAnnounce{} // pairHash → announces waiting for a peer
)

func confirmPair(c net.Conn, peerId, peerName string) {
	b, _ := json.Marshal(map[string]string{"peerDeviceId": peerId, "peerName": peerName})
	writeFrame(c, tPairConfirmed, b)
}

func removePending(key string, c net.Conn) {
	pendingMu.Lock()
	defer pendingMu.Unlock()
	list := pending[key]
	for i, pa := range list {
		if pa.conn == c {
			pending[key] = append(list[:i], list[i+1:]...)
			break
		}
	}
	if len(pending[key]) == 0 {
		delete(pending, key)
	}
}

// v1.5：NETDISPLAY_RELAY_TOKEN 非空时启用鉴权；空 = 放行（私网/向后兼容）
var serverToken = os.Getenv("NETDISPLAY_RELAY_TOKEN")

func tokenOK(m ctrlMsg) bool {
	if serverToken == "" {
		return true
	}
	return subtle.ConstantTimeCompare([]byte(m.Token), []byte(serverToken)) == 1
}

type room struct {
	sender     net.Conn
	created    time.Time
	persistent bool // pairHash 房间：不过期、可替换注册（v1.4 持久配对）

	// 抖动检测（v1.7）：pairHash 房间允许「后来者顶替」以便断线自愈，但两个都活着的
	// 发送端会互相顶替 —— 各自的「断线 3s 后重注册」逻辑正好互相踩，形成静默的无限
	// 互踢循环（双方日志都只显示「注册成功」，谁也发现不了）。这里数一下短时间内的
	// 顶替次数，超限就拒绝并回 room_occupied，打破循环。
	replaces    int
	lastReplace time.Time
}

const (
	flapWindow = 15 * time.Second // 在此窗口内的重复顶替算作抖动
	flapMax    = 3                // 窗口内允许的顶替次数，超过则拒绝
)

func isHex(s string) bool {
	for _, c := range s {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}

// v1.4：优先 pairHash(64 位小写 hex) 作为房间键，否则 6 位数字 code；均无效返回空串
func roomKey(m ctrlMsg) (string, bool) {
	h := strings.ToLower(m.PairHash)
	if len(h) == 64 && isHex(h) {
		return "h:" + h, true
	}
	if len(m.Code) == 6 {
		return "c:" + m.Code, false
	}
	return "", false
}

var (
	mu     sync.Mutex
	rooms  = map[string]*room{}
	joinRl = map[string][]time.Time{}
)

func main() {
	ln, err := net.Listen("tcp", listenAddr)
	if err != nil {
		log.Fatal(err)
	}
	if serverToken != "" {
		log.Printf("netdisplay-relay listening on %s (token auth ENABLED)", listenAddr)
	} else {
		log.Printf("netdisplay-relay listening on %s (token auth disabled)", listenAddr)
	}
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
			if !r.persistent && time.Since(r.created) > codeTTL {
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
	log.Printf("ERR → %s: %s", c.RemoteAddr(), reason)
	b, _ := json.Marshal(map[string]string{"reason": reason})
	writeFrame(c, tError, b)
}

// shortKey trims a room key for readable logs (h:<hex64> or c:<code>).
func shortKey(k string) string {
	if len(k) > 20 {
		return k[:20] + "…"
	}
	return k
}

func handle(c net.Conn) {
	if tc, ok := c.(*net.TCPConn); ok {
		tc.SetNoDelay(true)
		// 持久待命的发送端可能长时间无数据；开 keepalive 让 OS 探到半开连接
		// （进程被强杀 / 网络断），否则死连接会一直占着房间。
		tc.SetKeepAlive(true)
		tc.SetKeepAlivePeriod(30 * time.Second)
	}
	c.SetReadDeadline(time.Now().Add(unpairedTTL))
	t, p, err := readFrame(c)
	if err != nil {
		c.Close()
		return
	}
	var m ctrlMsg
	key, persistent := "", false
	if json.Unmarshal(p, &m) == nil {
		key, persistent = roomKey(m)
	}
	if key == "" {
		sendErr(c, "bad_request")
		c.Close()
		return
	}
	if !tokenOK(m) {
		sendErr(c, "unauthorized")
		c.Close()
		return
	}
	switch t {
	case tRegister:
		mu.Lock()
		replaces, lastReplace := 0, time.Time{}
		if old, exists := rooms[key]; exists {
			if !persistent {
				mu.Unlock()
				sendErr(c, "code_taken")
				c.Close()
				return
			}
			// pairHash 房间：新注册替换旧连接（断线重连自愈）——但要防互踢抖动
			replaces, lastReplace = old.replaces, old.lastReplace
			if time.Since(lastReplace) < flapWindow {
				replaces++
			} else {
				replaces = 1
			}
			if replaces > flapMax {
				mu.Unlock()
				log.Printf("register flapping on %s, rejecting (%d replaces in %v)", key, replaces, flapWindow)
				sendErr(c, "room_occupied")
				c.Close()
				return
			}
			lastReplace = time.Now()
			old.sender.Close()
		}
		rooms[key] = &room{
			sender: c, created: time.Now(), persistent: persistent,
			replaces: replaces, lastReplace: lastReplace,
		}
		mu.Unlock()
		log.Printf("REGISTER room=%s from=%s persistent=%v (waiting for join)", shortKey(key), c.RemoteAddr(), persistent)
		if persistent {
			c.SetReadDeadline(time.Time{}) // 持久待命，不超时
		} else {
			c.SetReadDeadline(time.Now().Add(codeTTL))
		}
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
		r, ok := rooms[key]
		if ok {
			delete(rooms, key)
		}
		mu.Unlock()
		log.Printf("JOIN room=%s from=%s roomFound=%v", shortKey(key), c.RemoteAddr(), ok)
		if !ok {
			sendErr(c, "code_not_found")
			c.Close()
			return
		}
		pair(key, r.sender, c)
		return
	case tPairAnnounce:
		// Mutual pairing (docs/11): hold this announce until a peer announces the
		// same room with a *different* deviceId, then confirm both.
		pendingMu.Lock()
		list := pending[key]
		// Dedup: drop a stale announce from the same deviceId.
		for i, pa := range list {
			if pa.deviceId == m.DeviceId {
				pa.conn.Close()
				list = append(list[:i], list[i+1:]...)
				break
			}
		}
		var peer *pendingAnnounce
		for _, pa := range list {
			if pa.deviceId != m.DeviceId {
				peer = pa
				break
			}
		}
		if peer != nil {
			// Remove the peer from pending and confirm both sides.
			nl := list[:0]
			for _, pa := range list {
				if pa != peer {
					nl = append(nl, pa)
				}
			}
			pending[key] = nl
			if len(pending[key]) == 0 {
				delete(pending, key)
			}
			pendingMu.Unlock()
			confirmPair(c, peer.deviceId, peer.name)
			confirmPair(peer.conn, m.DeviceId, m.Name)
			log.Printf("PAIR_CONFIRMED room=%s %s <-> %s", shortKey(key), m.DeviceId, peer.deviceId)
			c.Close()
			peer.conn.Close()
			return
		}
		// No peer yet — hold this announce open, waiting.
		pending[key] = append(list, &pendingAnnounce{conn: c, deviceId: m.DeviceId, name: m.Name, at: time.Now()})
		pendingMu.Unlock()
		log.Printf("PAIR_ANNOUNCE room=%s deviceId=%s (waiting for peer)", shortKey(key), m.DeviceId)
		// Block on a read so the conn stays open; returns on peer-confirm (peer
		// closes it), client disconnect, or TTL. Then clean up pending.
		c.SetReadDeadline(time.Now().Add(announceTTL))
		buf := make([]byte, 1)
		c.Read(buf)
		removePending(key, c)
		c.Close()
		return
	default:
		sendErr(c, "bad_request")
		c.Close()
	}
}

func pair(key string, sender, receiver net.Conn) {
	ok, _ := json.Marshal(map[string]bool{"ok": true})
	sender.SetReadDeadline(time.Time{})
	if writeFrame(sender, tPaired, ok) != nil || writeFrame(receiver, tPaired, ok) != nil {
		sender.Close()
		receiver.Close()
		return
	}
	start := time.Now()
	log.Printf("PAIRED room=%s sender=%s receiver=%s", shortKey(key), sender.RemoteAddr(), receiver.RemoteAddr())
	done := make(chan string, 2)
	var bytesSR, bytesRS int64
	pipe := func(dst, src net.Conn, who string, counter *int64) {
		buf := make([]byte, 256*1024)
		for {
			src.SetReadDeadline(time.Now().Add(idleTTL))
			n, err := src.Read(buf)
			if n > 0 {
				*counter += int64(n)
				if _, werr := dst.Write(buf[:n]); werr != nil {
					done <- who + "-write-fail"
					return
				}
			}
			if err != nil {
				done <- who + ":" + err.Error()
				return
			}
		}
	}
	go pipe(sender, receiver, "S→R", &bytesSR)
	go pipe(receiver, sender, "R→S", &bytesRS)
	first := <-done
	sender.Close()
	receiver.Close()
	<-done
	log.Printf("session closed room=%s after=%s firstClose=%s bytes(S→R=%d R→S=%d)",
		shortKey(key), time.Since(start).Round(time.Millisecond), first, bytesSR, bytesRS)
}
