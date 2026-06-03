---
title: Architecture
description: Single-binary CLI + daemon, IPC over UNIX socket, SQLite queue, human cadence.
---

## TL;DR

Single Zig binary. Two modes in the same executable: client (default) and daemon. The client sends a message to the daemon over a UNIX socket. The daemon queues to SQLite and drains sequentially by calling `say`. Auto-start: if the socket is dead, the client forks+execs the daemon before retrying.

Every piece exists to cut **time-to-first-audio (TTFA)**. Per-piece justification below.

## Diagram

```
┌─────────────┐    UNIX socket    ┌──────────────┐    pipe    ┌────────┐
│  agent-tts  │ ───────────────▶  │   daemon     │ ─────────▶ │  say   │
│  (client)   │ ◀── ack + id ─── │  (queue)     │  stdin     │ (afpla)│
└─────────────┘                   └──────┬───────┘            └────────┘
                                         │
                                         ▼
                                   ~/.cache/agent-tts/
                                     queue.db (SQLite WAL)
                                     sock (UNIX)
                                     daemon.pid
```

## Pieces

### Language: Zig 0.14+

- Native Apple Silicon binary, no runtime/GC
- Predictable latency (no stop-the-world)
- Direct FFI to Cocoa later if `say` stops being enough
- Stripped < 2MB

Version pinned in `build.zig.zon` — Zig still breaks between minor releases.

### CLI + daemon, same binary

Shrinks install surface. `agent-tts` with no args = client. `agent-tts daemon` = server. Detection via argv[1].

**Auto-start**: client tries to connect to the socket. On failure → `fork()` + `execve(self, "daemon", "--detach")` → retry with 10ms × 5 backoff. The first cold call pays ~500ms; subsequent calls hit ack in < 50ms.

### IPC: UNIX socket

`~/.cache/agent-tts/sock`. Faster than TCP loopback (no checksum, no TCP stack). Protocol: line-framed JSON.

```
→ {"op":"enqueue","text":"olá","voice":"Luciana","rate":180}
← {"ok":true,"id":42}
```

Socket cleanup: daemon registers SIGTERM/SIGINT handler → `unlink(sock)`. On startup, it checks whether the PID in `daemon.pid` is still alive before claiming an orphan socket.

### Queue: SQLite (WAL)

`~/.cache/agent-tts/queue.db`. Survives reboot + crash. WAL mode lets the worker drain without blocking `agent-tts queue` (read-only).

Minimal schema:

```sql
CREATE TABLE items (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  text TEXT NOT NULL,
  voice TEXT,
  rate INTEGER,
  state TEXT NOT NULL DEFAULT 'pending', -- pending|playing|done|skipped
  enqueued_at INTEGER NOT NULL,
  started_at INTEGER,
  finished_at INTEGER
);
```

Worker: 1 goroutine-equivalent (single-threaded loop). Never two `say` invocations in parallel — overlap is bad UX. Implicit mutex via the single-consumer queue.

### Audio driver: `say` (libexec)

`/usr/bin/say -v "Luciana (Premium)" -r 180`. Text via stdin. Full justification in [TTS engine](/motor/).

Pre-warm: at boot the daemon runs `say -v Luciana ""` to force the model into the Neural Engine. Without pre-warm, the first call pays an extra ~200-400ms.

### Human cadence

Default 180 WPM (typical Pt-BR speaker is ~160-180). Zig pre-processor does:

| Input | Output |
|---------|-------|
| `,` | + `[[slnc 150]]` |
| `.` `!` `?` | + `[[slnc 400]]` |
| `\n` | + `[[slnc 600]]` |
| `Sr.` | `Senhor` |
| `cf.` | `conforme` |
| `123` | `cento e vinte e três` (Pt-BR cardinals) |

`[[slnc N]]` directives are literals consumed by `say`, in milliseconds.

## Code layout

```
src/
  main.zig          # entry, parse argv, route client|daemon
  client.zig        # connect, enqueue, status
  daemon.zig        # accept loop + worker
  queue.zig         # SQLite wrapper
  tts.zig           # invokes say, manages the process, pre-warm
  preproc.zig       # normalization + pauses
  ipc.zig           # socket protocol (JSON-line)
build.zig
build.zig.zon
```

Flat. No subdirs until they earn it.

## Expected gotchas

- `say -v Luciana` silently fails if the voice isn't installed. Daemon validates with `say -v '?'` at boot and logs an explicit warning
- Orphan socket after SIGKILL — startup checks the PID file before claiming it
- SQLite without WAL blocks `queue` during `playing` — always WAL
- Zig stdlib still moves the child process API around between versions; isolate in `tts.zig`
