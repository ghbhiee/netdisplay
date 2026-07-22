#!/usr/bin/env bash
# NetDisplay agent-chat helper (Mac<->Windows Claude coordination).
# Token resolution: $CHAT_TOKEN, else ~/.netdisplay/chat-token, else `ssh 15 cat`.
# Usage:
#   agent-chat.sh post "message"           # post as $CHAT_FROM (default: mac-claude)
#   agent-chat.sh poll [sinceId]           # one-shot fetch (default since 0)
#   agent-chat.sh watch [sinceId]          # long-poll loop, prints new messages
#   agent-chat.sh info                      # print interop info
set -euo pipefail
BASE="https://15.tokencv.com:47900"
FROM="${CHAT_FROM:-mac-claude}"
tok() {
  if [ -n "${CHAT_TOKEN:-}" ]; then echo "$CHAT_TOKEN";
  elif [ -f "$HOME/.netdisplay/chat-token" ]; then cat "$HOME/.netdisplay/chat-token";
  else ssh 15 'cat /root/cc/agent-chat/token'; fi
}
T="$(tok)"
case "${1:-}" in
  post)  curl -s -X POST "$BASE/post" -H "Authorization: Bearer $T" -H "Content-Type: application/json" \
           --data "$(FROM="$FROM" TEXT="$2" python3 -c 'import json,os;print(json.dumps({"from":os.environ["FROM"],"text":os.environ["TEXT"]}))')"; echo ;;
  poll)  curl -s "$BASE/messages?since=${2:-0}" -H "Authorization: Bearer $T" | python3 -m json.tool ;;
  watch) SINCE="${2:-0}"; echo "watching from #$SINCE ..."; while true; do
           R="$(curl -s "$BASE/messages?since=$SINCE&wait=25" -H "Authorization: Bearer $T")";
           echo "$R" | python3 -c 'import sys,json;
d=json.load(sys.stdin)
import time
for m in d["messages"]:
    print(f"#{m[\"id\"]} [{m[\"from\"]}] {m[\"text\"]}")
    open("/tmp/.agentchat_last","w").write(str(m["id"]))';
           L="$(cat /tmp/.agentchat_last 2>/dev/null || echo $SINCE)"; SINCE="$L"; done ;;
  info)  curl -s "$BASE/info" -H "Authorization: Bearer $T" ;;
  *) echo "usage: $0 {post <text>|poll [since]|watch [since]|info}"; exit 1 ;;
esac
