# Relay（中转服务器）

Go，部署在 15.tokencv.com:47700（systemd `netdisplay-relay`）。
只做配对撮合 + 字节转发；支持 6 位 code 与 pairHash 两种房间键。
代码待 Windows 端 push（源在服务器 /opt/apps/netdisplay-relay/main.go）。规范见 docs/05-relay-server.md。
