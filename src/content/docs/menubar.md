---
title: Menubar UI
description: Native macOS menubar app for agent-tts — same UNIX-socket protocol as the CLI and the MCP server, third client on the wire.
---

## TL;DR

`AgentTTSMenubar` is a SwiftUI menubar app that gives the daemon a face. It speaks the same line-delimited TSV protocol the CLI and MCP server use — third client on `~/.cache/agent-tts/sock`, daemon unchanged. Live queue, click-to-skip, voice picker with cloned voices auto-discovered from disk. 321 KB binary, 911 Swift LOC, macOS 14+, Swift 5.9+.

Volume ducking and the Linux GTK4 equivalent are deferred to v1.10.1 — explicit honest scope in the [Changelog](/changelog/).

## Install

There is no signed `.app` yet — v1.10 ships the buildable Swift Package, not a brew cask. Build it from source:

```bash
cd ui/menubar
swift build -c release
.build/release/AgentTTSMenubar       # smoke run, unbundled
```

Wrap it into a `.app` bundle with the helper script:

```bash
./scripts/build-menubar.sh
open ui/menubar/build/AgentTTSMenubar.app
```

Then drag it into `Login Items` (System Settings → General → Login Items) so it starts on login alongside the daemon.

![AgentTTSMenubar status item — captured live from /Applications/AgentTTSMenubar.app on macOS 26.5](/agent-tts/screenshots/menubar-v1.10.1.png)

> v1.10.1 captures only the menubar strip. The popover screenshot (queue + voice picker open) lands in v1.10.2 alongside CoreAudio ducking + the signed brew cask.

## What's in the popover

- **Header** — title + refresh button (forces a queue re-poll).
- **Voice picker** — Luciana / Felipe / Faber / Amy plus any cloned voices discovered under `~/.cache/agent-tts/voices/<slug>/metadata.json` (same probe path `agent-tts --voice <slug>` uses). Selection persists to UserDefaults under `AgentTTSMenubar.selectedVoiceId`.
- **Queue list** — one row per item with a state dot (green = playing, grey = pending), the text preview, the engine + voice + rate, and the daemon's `id`. Polls every 750 ms while the popover is open, 0 polls while it's closed.
- **Footer** — Skip + Clear buttons (same semantics as `agent-tts skip` / `agent-tts clear`), last-poll round-trip readout in milliseconds, power button to quit.

## Protocol

The Swift client implements the v1.1 6-field `ENQUEUE` form and the matching `QUEUE` / `SKIP` / `CLEAR` ops. Same wire as [`src/ipc.zig`](https://github.com/biliboss/agent-tts/blob/main/src/ipc.zig):

```
→ ENQUEUE\t<engine>\t<lang>\t<voice>\t<rate>\t<text>\n
← OK\t<id>\n

→ QUEUE\n
← ITEM\t<id>\t<state>\t<engine>\t<voice>\t<rate>\t<text>\n
← ...
← END\n

→ SKIP\n
← OK\t<id>\n        (id=0 ⇒ nothing was playing)

→ CLEAR\n
← OK\t<count>\n     (count of dropped pending items)
```

The parser is permissive: it also accepts the v0.6 legacy `ITEM\t<id>\t<state>\t<voice>\t<rate>\t<text>` layout so a stale daemon doesn't break the UI.

## Architecture choices

| Decision | Rationale |
|---|---|
| Raw POSIX `Darwin.socket` instead of `Network.framework` NWConnection | NWConnection's callback model adds latency on the warm path the CLI publishes as 0.2-0.4 ms. The synchronous request/response shape is cleaner over plain BSD sockets |
| Swift Package, not Xcode project | Builds from the command line on any macOS with Command Line Tools — no Xcode dependency for CI, no `.xcodeproj` merge conflicts |
| `SocketProtocolCheck` standalone executable next to the XCTest target | XCTest is Xcode-only on macOS Command Line Tools, and Swift Testing's macro plugin is also Xcode-only. The XCTest file compiles under `#if canImport(XCTest)` so the package always builds; the executable provides a CI-portable smoke runner that exits non-zero on failure |
| `LSUIElement=true` (set both via Info.plist and `NSApp.setActivationPolicy(.accessory)`) | No dock icon, no app menu. Menubar-only is the whole point |
| Popover starts/stops polling on open/close | Saves IPC traffic — the daemon doesn't need a poll every 750 ms while the popover is closed |
| Click-to-skip only on the playing row in v1.10 | Daemon's `SKIP\n` targets the head of the queue. Per-id skip needs a daemon-side `SKIP\t<id>\n` extension. UI rows are clickable for forward-compat, so v1.10.1 plugs in without UI churn |

## Honest scope (deferred)

- **Volume ducking** — needs CoreAudio + entitlement + signing. v1.10.1
- **Linux GTK4 status icon** — different runtime, separate session. v1.10.1 or v1.11
- **Drag-to-reorder pending items** — needs a daemon-side `MOVE` op. v1.10.1
- **Per-id skip** — daemon extension, see above. v1.10.1
- **Signed `.app` + brew cask** — v1.10.1 alongside ducking

See also: [Architecture](/arquitetura/), [MCP server](/mcp/), [Changelog](/changelog/).
