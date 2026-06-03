---
title: Architecture
description: Single Zig binary, CLI + daemon over UNIX socket, SQLite WAL queue, two interchangeable TTS engines (libpiper + macOS say).
---

## TL;DR

Single Zig 0.16 binary. Two modes share one executable: client (default) and daemon. The client sends a message over a UNIX socket. The daemon stores it in a SQLite WAL queue and drains serially. Each item is routed to one of two engines: **libpiper** (neural, default) or **macOS `say`** (fallback). Audio plays through **zaudio** (PCM streaming) for piper or directly through `say` for the system voice. Auto-start is handled by **launchd**.

Every component exists to cut **time-to-first-audio (TTFA)**.

## Diagram

```
┌─────────────┐    UNIX socket    ┌────────────────────┐
│  agent-tts  │ ───ENQUEUE──────▶ │       daemon       │
│  (client)   │ ◀── OK + id ────  │  - accept loop     │
└─────────────┘                   │  - SQLite WAL      │
                                  │  - worker thread   │
                                  └────────┬───────────┘
                                           │ route by item.engine
                              ┌────────────┴────────────┐
                              ▼                         ▼
                       ┌─────────────┐          ┌───────────────┐
                       │  /usr/bin/  │          │   libpiper    │
                       │    say      │          │  (PiperEngine)│
                       │  -v Luciana │          │  → s16le PCM  │
                       └─────────────┘          └──────┬────────┘
                                                       │
                                                       ▼
                                                ┌──────────────┐
                                                │    zaudio    │
                                                │  (miniaudio) │
                                                └──────────────┘
```

Filesystem layout:

```
~/.cache/agent-tts/
  queue.db          SQLite WAL (items + state machine)
  sock              UNIX stream socket
  voices/           Piper ONNX models (downloaded once)
  daemon.out.log    launchd stdout
  daemon.err.log    launchd stderr

~/Library/LaunchAgents/
  io.github.biliboss.agent-tts.plist
```

## Components

### Language: Zig 0.16

- Native arm64 / x86_64 binary, no runtime, no GC
- Predictable latency, no stop-the-world
- Direct FFI to `libpiper`, `libsqlite3`, and `miniaudio` via `@cImport`
- ReleaseFast with libpiper linked: **~975 KB**

Version pinned in `build.zig.zon` — Zig still breaks between minor releases.

### CLI + daemon share the binary

Cuts install surface. `agent-tts` without args = client. `agent-tts daemon` = server. Dispatch by `argv[1]`.

The client does NOT fork the daemon. The daemon survives because of launchd (`agent-tts daemon install`), so the warm-path round-trip stays under a millisecond.

### IPC: UNIX socket

Path: `~/.cache/agent-tts/sock`. Faster than TCP loopback (no checksum, no TCP stack). Line-delimited TSV protocol:

```
→ ENQUEUE\t<engine>\t<voice>\t<rate>\t<text>\n
← OK\t<id>\n
```

Other ops:
- `QUEUE\n` → daemon emits `ITEM\t<id>\t<state>\t<engine>\t<voice>\t<rate>\t<text>\n` lines followed by `END\n`
- `SKIP\n` → SIGTERMs the current `say` PID (or signals piper playback to stop) → `OK\t<id>\n`
- `CLEAR\n` → marks every pending item as `skipped` → `OK\t<count>\n`

Cleanup: the daemon registers SIGTERM/SIGINT and unlinks the socket on exit. On startup it checks if the PID in `daemon.pid` is still alive before assuming an orphan socket.

### Queue: SQLite WAL

`~/.cache/agent-tts/queue.db`. Survives daemon crash, reboot, and SKIP. WAL mode lets the worker drain without blocking `agent-tts queue` reads.

Schema:

```sql
CREATE TABLE items (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  text TEXT NOT NULL,
  voice TEXT,
  rate INTEGER,
  engine TEXT NOT NULL DEFAULT 'say',
  state TEXT NOT NULL DEFAULT 'pending',
  enqueued_at INTEGER NOT NULL,
  started_at INTEGER,
  finished_at INTEGER
);
```

Worker = a single thread loop. Never two synth/playback in parallel — overlap kills UX. Mutual exclusion is implicit from the single-consumer queue.

Crash recovery on daemon boot: `UPDATE items SET state='pending' WHERE state='playing'` re-promotes orphan items from the previous run.

### Engine routing

Selected per item via the `engine` column. The worker picks the matching path:

| `item.engine` | Path |
|---------------|------|
| `say` | `tts.spawnSay(voice, rate, preprocessed_text)` → blocks on `wait()` |
| `piper` | `PiperEngine.synthToSamples(text)` → `AudioPlayer.streamS16le(samples, 22050)` |
| `cloned` (v1.4) | spawn `scripts/voice_synth.py` → drain s16le PCM on stdout → `AudioPlayer.streamS16le(samples, 22050)` |

If `--engine piper` arrives but the engine is not loaded (binary built without `-Dwith-piper=true`, or `AGENT_TTS_PIPER=1` was not set), the worker logs a warning and falls back to `say`. For `cloned`, missing embedding OR sidecar failure falls back to piper Faber when available, else `say` Luciana.

### libpiper FFI

Vendored from [OHF-Voice/piper1-gpl](https://github.com/OHF-Voice/piper1-gpl) at tag `v1.4.2`. Built once via `scripts/build-libpiper.sh`. Links against `libpiper.dylib` + `libonnxruntime.1.22.0.dylib` (resolved via `@rpath`).

`PiperEngine` is a Zig struct owning the C handle. Init loads the ONNX voice model (~400 ms cold), exposes `synthToSamples(text) → []i16`. Lives in daemon-scoped storage so the cold cost is paid once.

License: GPL-3.0-or-later. Built into the binary only when `-Dwith-piper=true`; without it, the binary is MIT/Apache.

### Audio: zaudio (miniaudio)

Vendored from [zig-gamedev/zaudio](https://github.com/zig-gamedev/zaudio). Linked against CoreAudio / AudioUnit / AudioToolbox frameworks on macOS. The daemon owns one `zaudio.Engine` instance.

`AudioPlayer.streamS16le(samples, 22050)` creates an `AudioBuffer` data source pinned to the source rate (22050 Hz for Faber). Without the explicit sample rate, miniaudio upsamples to the device rate (48000 Hz) and pitch shifts ~2.18× higher — a fix shipped in v1.0.

### Python sidecar (v1.4 — cloned engine only)

`agent-tts voice clone --sample <wav> --name <slug>` spawns `scripts/voice_clone.py` via `std.process.Child` to extract the XTTS-v2 speaker conditioning latents from the reference WAV. Synthesis at request time spawns `scripts/voice_synth.py`, which reads text on stdin and writes raw s16le mono 22050Hz PCM to stdout. The daemon drains stdout into a buffer + feeds the same `AudioPlayer.streamS16le` path Faber uses.

Spawn convention: `uv run --with TTS <script>` when `uv` is on PATH, else plain `python3 <script>` (assumes the venv created by `scripts/setup-voice-clone.sh` is activated). The script files at `scripts/voice_clone.py` + `scripts/voice_synth.py` carry SPDX MIT/Apache headers; Coqui TTS itself is MPL-2.0 and runs out-of-process — no MPL code is linked into the Zig binary.

Fallback chain (handled in `daemon.zig::fallbackCloned`): missing embedding OR sidecar exit ≠ 0 → piper Faber (when loaded) → `say` Luciana.

The "only Zig" lifecycle constraint is intentionally relaxed for this engine only. Faber + say still work without Python. See `docs/motor.md` "Cloned voices (v1.4)" for the licensing + UX rationale.

### Drive: `say` (libexec)

`/usr/bin/say -v "Luciana (Premium)" -r 330`. Used as the fallback engine.

Pre-warm: the daemon boots `say -v Luciana ""` to load the voice into the Neural Engine. Without pre-warm, the first call pays an extra 200-400 ms.

### Pt-BR preprocessor (v0.5)

Runs before each engine sees the text. Three transforms, single pass each, allocated in a per-utterance arena:

| Input | Output |
|-------|--------|
| `,` | `, [[slnc 150]]` |
| `.` `!` `?` | `<punct> [[slnc 400]]` |
| `\n` | `[[slnc 600]]` |
| `Sr.` | `Senhor` |
| `cf.` | `conforme` |
| `123` | `cento e vinte e três` (cardinals 0..9999) |
| `R$` | `reais` |

`[[slnc N]]` directives are literal `say` commands; piper ignores them.

Total wall time: 2-5 µs per message. No TTFA risk.

### launchd auto-start

`agent-tts daemon install` writes `~/Library/LaunchAgents/io.github.biliboss.agent-tts.plist` and bootstraps it into the `gui/<uid>` domain. KeepAlive uses the `SuccessfulExit=false` dict form — a clean `bootout` actually stays out.

Plist write is atomic (`createFileAtomic` + `replace`). The `HOME` env var is injected explicitly because launchd does not inherit it pre-login.

## Code layout

```
src/
  main.zig         # entry, argv routing, ttfa-bench + piper-test subcommands
  client.zig       # enqueue, queue, skip, clear
  daemon.zig       # accept loop, worker, engine routing
  queue.zig        # SQLite WAL wrapper, schema migration
  ipc.zig          # line protocol, sanitize, Engine enum
  tts.zig          # spawn `say`
  piper.zig        # libpiper FFI (GPL-3.0-or-later)
  audio.zig        # zaudio.Engine wrapper
  preproc.zig      # Pt-BR cadence + abbreviations + cardinals
  launchd.zig      # LaunchAgent install / uninstall / status
  voice.zig        # v1.4 — `voice clone` / `voice list` subcommands

scripts/
  voice_clone.py        # v1.4 — XTTS-v2 speaker latent extraction
  voice_synth.py        # v1.4 — XTTS-v2 PCM synthesis to stdout
  setup-voice-clone.sh  # v1.4 — uv venv bootstrap
```

Flat. No subdir until it hurts.

## Locked gotchas

- `say -v Luciana` silently fails if the voice is not installed. The daemon validates with `say -v '?'` at boot and logs a warning.
- Orphan socket after SIGKILL — startup checks the PID file before reusing it.
- SQLite without WAL blocks `queue` during `playing`. Always WAL.
- `AudioBuffer.Config.sample_rate` must be set explicitly; the default upsamples to engine rate and shifts pitch.
- espeak-ng (under libpiper) caps phoneme source paths at 160 bytes. Build libpiper in a short path (`/tmp/agent-tts-piper-build`); the vendor script does this for you.
- `char32_t` in `piper.h` fails Zig's `translate-c`. Shim with `@cDefine("char32_t", "uint32_t")` before `@cInclude`.
