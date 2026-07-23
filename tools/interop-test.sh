#!/usr/bin/env bash
# NetDisplay CLI-only interop harness (no GUI, shared fixed pairing).
#
#   interop-test.sh recv [seconds]   # join the shared room; if a Sender is
#                                     # standing by, decode + report RECV_STATS.
#   interop-test.sh send [seconds]   # run a Mac Sender in relay standby on the
#                                     # shared room so the peer can join & test.
#
# Secrets are read from the 15 server (never hard-coded here). Requires ssh 15.
set -uo pipefail
MODE="${1:-recv}"
SECS="${2:-20}"
HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="$HERE/../mac/.build/debug/netdisplay-sender"
RELAY="15.tokencv.com:47700"
CHAT="$HERE/agent-chat.sh"

[ -x "$BIN" ] || { echo "build first: (cd mac && swift build)"; exit 1; }

relay_token() { ssh 15 "grep -oE 'NETDISPLAY_RELAY_TOKEN=[^ ]+' /etc/systemd/system/netdisplay-relay.service.d/token.conf" | cut -d= -f2; }
# Two-room model: recv reads FROM the room where Windows is the standby sender;
# send stands by on the room where Mac is the sender. No cross-direction collision.
secret_file() { [ "$MODE" = "send" ] && echo secret-mac-sends || echo secret-win-sends; }
shared_secret() { ssh 15 "cat /root/cc/agent-chat/$(secret_file)"; }

TOKEN="$(relay_token)"; SECRET="$(shared_secret)"
[ -n "$TOKEN" ] && [ -n "$SECRET" ] || { echo "could not read token/secret from 15"; exit 1; }

LOG="/tmp/nd_interop_${MODE}.log"

if [ "$MODE" = "send" ]; then
  # send replaces any prior sender (incl. a standby); leaves receivers alone.
  pkill -f "netdisplay-sender relay" 2>/dev/null; sleep 1
  echo "Mac Sender standby on shared room for ${SECS}s (peer can 'receive --secret <shared>' now)…"
  caffeinate -u -t "$((SECS+5))" >/dev/null 2>&1 &
  "$BIN" relay --server "$RELAY" --token "$TOKEN" --secret "$SECRET" --width 1920 --height 1080 --bitrate 15 >"$LOG" 2>&1 &
  P=$!; sleep "$SECS"; kill "$P" 2>/dev/null; wait "$P" 2>/dev/null || true
  grep -E "registered|PAIRED|encoder ready" "$LOG" | tail -5
  exit 0
fi

# recv mode — only clears prior receivers, so a local standby SENDER survives.
pkill -f "netdisplay-sender receive" 2>/dev/null; sleep 1
echo "joining shared room for ${SECS}s…"
caffeinate -u -t "$((SECS+5))" >/dev/null 2>&1 &
"$BIN" receive --server "$RELAY" --token "$TOKEN" --secret "$SECRET" --codecs hevc422,hevc,h264 \
       --stats-after 5 --stats-repeat >"$LOG" 2>&1 &
P=$!; sleep "$SECS"; kill -INT "$P" 2>/dev/null; sleep 1; kill "$P" 2>/dev/null; wait "$P" 2>/dev/null || true

if grep -q "handshake OK" "$LOG"; then
  STATS="$(grep "RECV_STATS" "$LOG" | tail -1 | sed 's/^RECV_STATS //')"
  DIM="$(grep -oE 'stream [0-9]+x[0-9]+@[0-9]+ scale=[0-9]+ codec=[a-z0-9]+' "$LOG" | tail -1)"
  echo "PASS: $DIM"
  echo "RECV_STATS: $STATS"
  CHAT_FROM=mac-claude "$CHAT" post "interop-test recv PASS: $DIM · $STATS" >/dev/null 2>&1 || true
elif grep -q "code_not_found" "$LOG"; then
  echo "no standby Sender in the shared room yet (peer needs to run a standby sender)."
else
  echo "FAIL / no handshake:"; grep -E "ERROR|RELAY_ERROR|closed" "$LOG" | tail -3
fi
