---
title: What's next
description: Two next versions of agent-tts (v1.9, v1.10) — web playground and menubar UI.
---

## TL;DR

**v1.6, v1.7, and v1.8 shipped on 2026-06-03** — voice cloning (baseline in [`_qa/v1.6-baseline.md`](https://github.com/biliboss/agent-tts/blob/main/_qa/v1.6-baseline.md)), streaming text input (`agent-tts stream` + `say_stream` MCP tool), SSML prosody (`<emphasis>` / `<break>` / `<prosody>` / `<say-as>`). Remaining slate (**v1.9, v1.10**) points at two audiences: people who want to try every voice in a browser, and people who want a face on the daemon.

Vote, watch, or send a PR at [biliboss/agent-tts](https://github.com/biliboss/agent-tts).

---

<!-- v1.6 voice cloning + v1.7 streaming text input shipped 2026-06-03; see Changelog. -->

---

## v1.9 — Web playground · *Try every voice without installing*

> The fastest pitch is a `<button>` that says "hear it now." Today the only way to hear Faber is `brew install` + `scripts/build-libpiper.sh` + a 63 MB voice download.

**The problem today.** Discovery requires commitment. The Starlight docs site is read-only — nobody hears the voice before they install.

**What ships.**
- `agent-tts wasm` build target — Zig compiles the synth path to WebAssembly (Piper's ONNX runtime has a WASM variant; we wire it through `@cImport`)
- Embedded interactive widget on `biliboss.github.io/agent-tts/motor/` — text input + voice dropdown + "Speak" button, all in-browser, no server
- Sample voice library hosted on Cloudflare R2 (free CDN egress); first hit downloads the ONNX, browsers cache
- Latency bench: *first-audio TTFA in a cold browser tab* (target < 1.5 s including model fetch over a residential connection)

**Why now.** Top-of-funnel discovery for an OSS TTS project is "press button, hear voice." Anything else loses 90% of the curiosity-driven traffic.

**Who cares.**
- First-time visitors who don't yet trust the install.
- Tweet readers who land for one demo.
- Podcasters / editors auditioning voices before they wire one into a workflow.

---

## v1.10 — Menubar UI · *Voice agent gets a face*

> The daemon runs invisible. Skip/clear/queue are CLI verbs. v1.10 ships a 200×400 menubar app showing the queue, the currently-playing item, and a one-click voice picker.

**The problem today.** `agent-tts queue` is the only window into the daemon. There is no skip button, no volume slider, no visual cue that the agent just started speaking.

**What ships.**
- macOS menubar app (Swift, SwiftUI, ~1 MB binary) talking the same UNIX socket protocol as the CLI
- Live queue with `pending` / `playing` highlight, click-to-skip, drag-to-reorder
- Voice picker dropdown (Faber / Amy / Luciana / cloned) — switches the daemon's default mid-session
- "Volume duck while speaking" toggle — drops other apps' output to 30% during agent speech via CoreAudio AVAudioSession ducking
- Linux equivalent ships as a GTK4 status icon (best-effort, less polish)
- The daemon stays unchanged — UI is a thin LiveView-style client, all state lives on the socket

**Why now.** Once an agent speaks well, the next question is "how do I see what it's doing?" v1.10 makes the daemon legible. Also, "menubar app" is the proof-point that puts agent-tts on Product Hunt and into "AI tools for Mac" lists.

**Who cares.**
- Power users who like agent voice but want visible controls.
- Mac users who expect every background daemon to have a menubar entry.
- Onlookers — the menubar icon is the only ad agent-tts will ever buy.

---

## How to influence the order

The next milestone is the one with the loudest signal.

- 👍 [GitHub issues with the `roadmap` label](https://github.com/biliboss/agent-tts/labels/roadmap)
- ⭐ Star the repo — repo traffic guides priority
- 🛠 Send a PR — the changelog will name you

See also: [Roadmap](/roadmap/), [Changelog](/changelog/), [TTS engine](/motor/), [MCP server](/mcp/).
