[中文](README.md) · **English**

# NetDisplay

**Turn one computer into a second display for another** — over the network, no HDMI/DP cable. Project your
**whole screen** (as a real extended display) or just **a single app window** to another machine. Works over
LAN / USB4 direct connection, and through a **pairing relay** for machines on different networks
(no port forwarding, no NAT traversal setup).

**Universal, symmetric, cross-platform**: between any two computers — Mac↔Windows, Windows↔Windows,
Mac↔Mac — **either side can send or receive**. Pair once, then project both ways.

## Use cases and latency (important)

- **The main use case is LAN**: single-digit millisecond RTT on the same network, <1ms over USB4 — this is a
  genuinely **interactive** extended display (dragging windows, typing and moving the mouse on that screen all
  feel responsive).
- **It also works across the public internet (via relay)**: latency depends on where your relay node is
  (~300ms measured through an overseas node). That's closer to **low-latency remote viewing / presenting** —
  the picture is smooth, but it isn't a desktop you'd want to interact with in real time. A nearby relay node
  brings this down to tens of milliseconds.
- In short: **LAN = a real extended display; across the internet = remote screen viewing.** Same code, the
  difference is purely the network.
- ⚠️ Two machines sharing the same **public IP does not mean they can connect directly** (a coincidence of
  carrier-grade NAT — they may not be reachable at layer 2). A direct connection needs them genuinely on the
  same LAN, or on a USB4 link.

## Download

Grab the latest build from [Releases](https://github.com/ghbhiee/netdisplay/releases):

| Platform | File | Notes |
|---|---|---|
| macOS 14+ | `NetDisplay-macOS.zip` | Unzip to get `NetDisplay.app`, move it to Applications. It lives in the menu bar. |
| Windows 10/11 | `NetDisplay-<version>-portable.exe` | Portable, no installer — just run it. |

**First launch on macOS**: the app is self-signed, so macOS will say it can't verify the developer —
right-click the app → **Open** → **Open** again. You also need to tick NetDisplay under
**System Settings → Privacy & Security → Screen Recording** (required to capture anything).

**Install it on both machines** — it's one app that both sends and receives; you pick the role in the UI.

## Quick start (pair → project)

1. Open NetDisplay on both computers.
2. On either one, click **＋ Add device** and pick how to pair:
   - **Via relay (pairing code)** — for machines on different networks. One side clicks *Generate* to get a
     6-character code, the other types **the same code**, and **both click Pair**. It only counts as paired
     once the relay matches you up (the server just introduces the two ends — it stores nothing).
     ⚠️ Using the relay requires the **Relay settings** to be filled in first (see below); the Pair button
     stays disabled while the relay is unreachable.
   - **Direct (peer IP)** — for machines on the same LAN, **no server involved**. Both sides enter **the same
     pairing code** plus the other machine's LAN IP, and each clicks Pair.
3. Once paired, go to **Project this machine**, choose what to send (whole screen, or a specific app window),
   and click **Start projecting**. The other side needs its **receive service** switched on first.

### Video quality (configured on the sending side only)

Quality is decided by the **sender**. The receiving side has no quality settings — it doesn't need any:

| What you choose | Streamed resolution | How the other side shows it |
|---|---|---|
| **Match their screen** (default) | The peer's display resolution | Second display / fullscreen |
| **Specific resolution** | Your value, **automatically reduced if it exceeds their screen** | A window |
| **Project a single window** | The window's own size, also capped to their screen (**scaled proportionally — never stretched, never upscaled**) | A window |

Changing resolution or frame rate **takes effect live** while projecting (the source is rebuilt and the peer
is notified) — no need to disconnect and reconnect.

## The relay server — when you need it, how to run it, how to use it

### Do you need it?

**Not on the same LAN** — use *Direct (peer IP)* instead; the video goes peer-to-peer with the lowest latency.

**You need it when the two machines aren't on the same network** (e.g. your Mac at home projecting to a
Windows box at the office). The relay does exactly two things: **matches up the pairing** (introduces two ends
using the same code) and **forwards bytes** (transparent two-way forwarding once paired). It **doesn't parse
video, doesn't store anything, and has no user accounts** — which makes it very cheap to self-host.

> Want to use one without running it yourself? Point **Relay settings** at any machine you trust that's
> running this service. This project **does not provide a public server** — please run your own (5 minutes).

### Self-hosting (Linux + Go 1.19+)

```bash
git clone https://github.com/ghbhiee/netdisplay.git
cd netdisplay/relay
go build -o netdisplay-relay .
sudo cp netdisplay-relay /usr/local/bin/
```

Set an access token (**strongly recommended** — the port is exposed to the internet) and run it as a
systemd service:

```bash
sudo cp netdisplay-relay.service /etc/systemd/system/
sudo mkdir -p /etc/systemd/system/netdisplay-relay.service.d
printf '[Service]\nEnvironment=NETDISPLAY_RELAY_TOKEN=%s\n' "$(openssl rand -hex 24)" \
  | sudo tee /etc/systemd/system/netdisplay-relay.service.d/token.conf
sudo systemctl daemon-reload
sudo systemctl enable --now netdisplay-relay
sudo journalctl -u netdisplay-relay -f     # confirm "listening on :47700"
```

Open **TCP 47700** in your firewall (exposed directly — don't put nginx in front; a reverse proxy is a poor
fit for raw long-lived TCP forwarding):

```bash
sudo ufw allow 47700/tcp
```

Note down the token you just generated
(`cat /etc/systemd/system/netdisplay-relay.service.d/token.conf`).

### Using it in the app

Open **Relay settings** on both machines and enter **the same**:

- **Relay server address**: `your-host-or-ip:47700`
- **Access token**: the string generated above (leave empty for no auth — only sensible on a private network)

It should immediately show *Relay · available XXms*. The **Pair** button only becomes clickable once it is.

**Security**: the server forwards a raw byte stream and never parses the content; a pairing code can only be
matched while **both** ends are actively sitting in the pairing dialog, and it stops working the moment you
close that window — so nobody can grab a code and latch onto your session.

## Projecting the whole screen from Windows: install a virtual display (VDD)

**Only needed when Windows is the *sending* side and you want to project a genuinely *new* extended screen.**

Windows has no system-level virtual display API (macOS has `CGVirtualDisplay`, which is why **nothing extra is
needed on Mac**). Without VDD, projecting "the whole screen" from Windows can only **mirror an existing
display** — you'd see exactly what's already on that monitor. With VDD you get an extra display that the
system treats as real; project *that* one and you have a true **extended desktop** you can drag windows onto.

- Where to install it: **on the Windows machine that does the projecting** (the sender). **The receiving side
  doesn't need it.**
- Project page: **https://github.com/VirtualDrivers/Virtual-Display-Driver**
  (an IddCx indirect display driver, Windows 10/11, MIT licensed, free and open source)
- **The driver is signed** (free signing from the SignPath Foundation), so you do **not** need to disable
  driver signature enforcement. Some older tutorials tell you to enable test mode or turn signing off —
  that's **unnecessary** for this driver, and not something you should do.

### Installation

1. Install the [Microsoft Visual C++ Redistributable](https://aka.ms/vs/17/release/vc_redist.x64.exe)
   (`vcruntime140` is a dependency; it will error out without it).
2. Get VDD, either way:
   ```powershell
   winget install --id=VirtualDrivers.Virtual-Display-Driver -e
   ```
   or download and extract the archive from
   [Releases](https://github.com/VirtualDrivers/Virtual-Display-Driver/releases) (portable, no installer).
   **ARM64** devices need the manual installation method described in their docs.
3. Run **Virtual Driver Control (VDC)** **as Administrator** and click **Install**.
4. Under **Settings → System → Display** you'll see an extra monitor — set it to **Extend these displays**
   (**not** "Duplicate"). You can add or adjust that virtual screen's resolution/refresh rate in VDC.
5. Open NetDisplay → **Project this machine** → under "whole screen" you'll now see `Screen 1 / Screen 2` —
   pick **the virtual one** → start projecting.

Now drag a window onto that virtual screen and it appears on the other machine — an actual extra display,
not a copy of one you already have.

> ⚠️ **Uninstall VDD from VDC before doing a major GPU/chipset driver update**, otherwise you may hit a black
> screen or display-priority conflicts. If you do get a black screen: boot into **Safe Mode** → Device Manager
> → uninstall that virtual display adapter.

## Repository layout

| Directory | Contents | Platform / language |
|---|---|---|
| `mac/` | Mac side (send + receive, menu-bar app) | macOS / Swift (SwiftPM) |
| `windows/` | Windows side (send + receive) | Windows / Electron + WebCodecs |
| `relay/` | Relay server (pairing rendezvous + byte forwarding) | Linux / Go |
| `docs/` | Protocol spec (source of truth), architecture, per-platform progress | Markdown |

## Building from source

- **Mac**: `cd mac && swift build -c release`, or `bash scripts/make-app.sh release` to produce the
  menu-bar app.
- **Windows**: see `windows/` (`npm install && npm start`, or `npm run dist` for the portable exe).
- **Protocol**: read [`docs/02-protocol.md`](docs/02-protocol.md) first — it's the single source of truth
  (written in Chinese).

## How this was built

Two AI agents (one owning the Mac side, one owning the Windows side) developed their respective platforms,
**with the Mac side leading architecture**, syncing code and requirements through this repository. Protocol
changes go into `docs/02-protocol.md` with a changelog entry before any code changes.

## Author

guohongbo · <guohongbo@outlook.com> · <https://github.com/ghbhiee/netdisplay>

## License

Uses the private `CGVirtualDisplay` headers from
[peetzweg/opendisplay](https://github.com/peetzweg/opendisplay) (GPL-3.0); this project is for personal use
and follows GPL-3.0 as well.
