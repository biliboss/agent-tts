---
title: Roadmap
description: v0.1 → v1.2 shipped 2026-06-03 in a single session. v1.3 → v1.5 in What's next.
---

## TL;DR

v0.1 → v1.2 shipped on **2026-06-03**, in one session, behind one KPI. Nine milestones, each with a published measurement. Universal binary, brew tap, launchd auto-start in v1.0; sentence-streaming for long inputs in v1.2.

v1.3 and beyond are scoped for marketing and engineering value in [What's next](/whats-next/).

## v0.1 → v1.2 — Shipped

Every milestone has a published baseline in [`_qa/`](https://github.com/biliboss/agent-tts/tree/main/_qa) and a section in the [Changelog](/changelog/).

| Milestone | Focus | Result | Date |
|-------|------|--------|------|
| **v0.1** | `say` direct, no daemon | spawn 0.8 ms, 415 KB binary | 2026-06-03 |
| **v0.2** | Daemon + UNIX socket + in-memory FIFO | round-trip ACK < 0.1 ms, 455 KB | 2026-06-03 |
| **v0.3** | SQLite WAL queue + `queue` / `skip` / `clear` | survives `kill -9`, 476 KB | 2026-06-03 |
| **v0.4** | launchd `daemon install \| uninstall \| status` | 10 ms install round-trip | 2026-06-03 |
| **v0.5** | Pt-BR preprocessor (cardinals, abbreviations, pauses) | 2-5 µs / msg, 26 unit tests | 2026-06-03 |
| **v0.6** | libpiper FFI baseline | piper init 400 ms, synth + WAV 100 ms warm | 2026-06-03 |
| **v0.7** | zaudio streaming + `--engine say\|piper` routing | piper synth warm **91 ms** | 2026-06-03 |
| **v1.0** | Universal binary + brew formula + GitHub Pages docs | universal 1.8 MB, host 918 KB | 2026-06-03 |
| **v1.2** | Sentence chunking + pipelined synth/playback | long-input first-audio **41-52 ms** (down from ~3 s), gap median 0.02 ms | 2026-06-03 |

## KPI delivered

Every milestone was measured against **time-to-first-audio (TTFA)**.

| Target | Acceptance | Measured |
|---|---|---|
| Warm daemon say | < 300 ms | round-trip 0.1 ms + spawn 0.8 ms + playback ✅ |
| Piper warm synth (short) | < 1 s | **91 ms** ✅ |
| Piper first-audio (long, v1.2) | < 200 ms | **41-52 ms** ✅ |
| Inter-chunk gap (v1.2) | < 10 ms | **0.02 ms median, 0.61 ms max** ✅ |
| Cold daemon boot | < 800 ms | pre-warm 280 ms + zaudio 79 ms + piper 373 ms = ~720 ms ✅ |

Baselines: [`_qa/v0.1` … `_qa/v1.2`](https://github.com/biliboss/agent-tts/tree/main/_qa). Real audio-device dtruss not captured (SIP-on host); documented honestly in `_qa/v1.0-baseline.md`.

## Installation

```bash
# v1.0 — via tap (waiting for first signed release tarball):
brew tap biliboss/tap
brew install biliboss/tap/agent-tts

# From source today:
git clone https://github.com/biliboss/agent-tts.git
cd agent-tts
zig build -Doptimize=ReleaseFast
cp zig-out/bin/agent-tts /opt/homebrew/bin/

# Auto-start at login:
agent-tts daemon install
```

Piper engine requires the vendor build:

```bash
./scripts/build-libpiper.sh
./scripts/fetch-voice.sh
zig build -Doptimize=ReleaseFast -Dwith-piper=true
```

launchd plist lives at `~/Library/LaunchAgents/io.github.biliboss.agent-tts.plist`.

## What's next (v1.1, v1.3 → v1.5)

See [What's next](/whats-next/) for the marketing roadmap. Short version:

| | Theme | Headline |
|---|---|---|
| v1.1 | Multilingual | Speak your stack — code-switch Pt + En cleanly |
| v1.3 | Cross-platform | agent-tts on Linux (and Windows when you ask) |
| v1.4 | Voice cloning | Your voice, your agent |
| v1.5 | MCP server | Native Claude Code voice — drop the shell-out |

## Locked nots

- No embedded voice model in the binary (breaks the SSD goal).
- No Windows in v1.0. Linux v1.3.
- No parallel TTS (overlap = bad UX).
- No Cocoa / AVSpeechSynthesizer until `say` proves insufficient.
- No YAML config before v1.1 (YAGNI).
- No cloud sync, no usage telemetry, no account, no quota. Ever.
