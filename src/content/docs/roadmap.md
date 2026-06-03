---
title: Roadmap
description: v0.1 → v1.0 in short milestones. Each milestone tied to the KPI.
---

## TL;DR

6 milestones to v1.0. Each one validates a hypothesis against the KPI (time-to-first-audio).

| Milestone | Focus | Acceptance criteria | Target |
|-------|------|--------------------|------|
| v0.1 | `say` direct, no daemon | Pt-BR voice plays. TTFA measured (cold baseline) | 2026-06-07 |
| v0.2 | Daemon + socket + in-memory queue | Second call hits warm daemon, TTFA < 400ms | 2026-06-14 |
| v0.3 | SQLite WAL, `queue`/`skip`/`clear` | Queue survives daemon crash | 2026-06-21 |
| v0.4 | launchd auto-start | Mac boot → daemon comes up without interactive login | 2026-06-28 |
| v0.5 | Preprocessor (numbers, abbreviations, pauses) | Text with numbers + abbreviations sounds human | 2026-07-05 |
| v0.6 | libpiper FFI baseline | brew install cmake + build libpiper from OHF-Voice/piper1-gpl, `@cImport piper.h`, link `libpiper.dylib`, `PiperEngine` struct in the daemon, Faber voice synth via the C API | 2026-07-15 |
| v0.7 | zaudio streaming PCM + engine routing | `--engine say\|piper` on the client, daemon routes. zaudio replaces afplay/say-inline. Piper TTFA warm < 1s | 2026-07-22 |
| **v1.0** | Universal binary, brew tap | `brew install gabriel/tap/agent-tts` works, `say` warm TTFA < 300ms, piper warm TTFA < 1s | 2026-07-29 |

## v1.1+ (not committed)

- Multilingual Pt-BR ONNX voice (fix EN code-switch — depends on XTTS-v2 ONNX export stabilizing, or an alternative)
- Linux build (Zig cross-compile)
- YAML config
- Multiple named queues (`--queue notify`, `--queue chatter`)
- Streaming chunks for long text (first chunk before pre-processing the rest)

## Installation (planned)

```bash
# during dev
zig build -Doptimize=ReleaseFast
sudo cp zig-out/bin/agent-tts /usr/local/bin/

# launchd auto-start
agent-tts daemon install

# v1.0
brew install gabriel/tap/agent-tts
```

`launchd` plist at `~/Library/LaunchAgents/cloud.mukutu.agent-tts.plist`.

## KPI measurement

Each milestone measures TTFA in 3 scenarios and publishes to [_qa/] in the repo:

1. **Cold** — daemon stopped, first call
2. **Warm** — daemon running, voice pre-loaded
3. **Burst** — 5 calls in 100ms (measures backpressure)

Method: `dtruss -t write` on the `say` PID, capturing the first write to the audio device. Cross-check with `ffmpeg` recording the speaker output and detecting the first sample > -40dB.

Without a published measurement, the milestone doesn't close.

## Don't do

- Don't embed the voice model in the binary (breaks SSD)
- Don't support Windows in v1.0
- Don't run TTS in parallel (overlap = bad UX)
- Don't use Cocoa/AVSpeechSynthesizer before proving `say` is insufficient
- Don't add a config file before v0.5 (YAGNI)
