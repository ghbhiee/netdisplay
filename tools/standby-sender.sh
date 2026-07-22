#!/usr/bin/env bash
# Persistent Mac standby sender — decouples cross-machine testing from timing.
# Registers on the relay's shared pairHash room and waits; the peer can `receive
# --secret <shared>` anytime to test Mac->peer, without both sides being online
# at once. Streams a BLANK virtual display (NOT your real screen); idle (no
# encoding) until a peer actually joins; gated by relay token + shared secret.
# Survives across loop iterations (nohup). Idempotent: safe to call every tick.
#
#   standby-sender.sh start|status|stop
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="$HERE/../mac/.build/debug/netdisplay-sender"
RELAY="15.tokencv.com:47700"
PIDF="$HOME/.netdisplay/standby-sender.pid"
LOG="/tmp/nd_standby_sender.log"
mkdir -p "$HOME/.netdisplay"

relay_token() { ssh 15 "grep -oE 'NETDISPLAY_RELAY_TOKEN=[^ ]+' /etc/systemd/system/netdisplay-relay.service.d/token.conf" | cut -d= -f2; }
shared_secret() { ssh 15 'cat /root/cc/agent-chat/test-pair-secret'; }
alive() { [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF" 2>/dev/null)" 2>/dev/null; }

case "${1:-status}" in
  start)
    if alive; then echo "already running (pid $(cat "$PIDF"))"; exit 0; fi
    [ -x "$BIN" ] || { echo "build first: (cd mac && swift build)"; exit 1; }
    T="$(relay_token)"; S="$(shared_secret)"
    [ -n "$T" ] && [ -n "$S" ] || { echo "could not read token/secret from 15"; exit 1; }
    nohup "$BIN" relay --server "$RELAY" --token "$T" --secret "$S" \
          --width 1280 --height 800 --bitrate 12 >"$LOG" 2>&1 &
    echo $! > "$PIDF"; disown 2>/dev/null || true
    sleep 2
    echo "started (pid $(cat "$PIDF")): $(grep -E 'registered|waiting for peer' "$LOG" | tail -1)"
    ;;
  status)
    if alive; then echo "running (pid $(cat "$PIDF"))"; else echo "not running"; fi
    ;;
  stop)
    if alive; then kill "$(cat "$PIDF")" 2>/dev/null; fi
    rm -f "$PIDF"; pkill -9 -f "netdisplay-sender relay" 2>/dev/null || true
    echo stopped
    ;;
  *) echo "usage: $0 {start|status|stop}"; exit 1 ;;
esac
