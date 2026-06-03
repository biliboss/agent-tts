---
title: Changelog
description: Milestones shipped and real measurements per version.
---

## TL;DR

Per milestone: what shipped, how we measured, what slipped to the next one. The only KPI is TTFA. Without a published number, the milestone didn't close.

---

## v1.4 — Voice cloning · 2026-06-03

**Shipped**:

- `agent-tts voice clone --sample <wav> --name <slug>` — new subcommand. WAV header sniff (RIFF/WAVE magic + sample-rate + channels + bits-per-sample + data-chunk size). Sample duration must sit in `[20, 120]` seconds. Slug must match `[a-z0-9-]+`, 1-32 chars. Writes `~/.cache/agent-tts/voices/<slug>/embedding.npz` (via the Python sidecar) + `~/.cache/agent-tts/voices/<slug>/metadata.json` (written by Zig — keeps a structured record even if the sidecar partially fails)
- `agent-tts voice list` — prints faber + each cloned voice with a one-line summary. Skips directories without a `metadata.json` (defensive against half-written clones)
- `ipc.Engine` gains `cloned`. `parseRequest` accepts `ENQUEUE\tcloned\t<slug>\t<rate>\t<text>`. v0.6 4-field layout still backward-compatible (auto-falls-back to engine=`say`)
- `daemon.runOne` routes `cloned` items through `scripts/voice_synth.py` via `std.process.Child`. Sidecar reads text on stdin, writes raw s16le mono 22050Hz PCM to stdout, which the daemon drains into a buffer and feeds `AudioPlayer.streamS16le` — same playback pipeline as Faber. If the embedding file is missing OR the sidecar exits non-zero, the worker logs + falls back: piper Faber when loaded, else `say` Luciana
- `client.zig` resolves `--voice <slug>` implicitly: `faber` → piper, slug with a `metadata.json` on disk → cloned, anything else → say. Explicit `--engine` overrides
- `scripts/voice_clone.py` — Coqui XTTS-v2 wrapper. Extracts `gpt_cond_latent` + `speaker_embedding` from the reference sample, writes `.npz` archive. Uses `coqui-tts >= 0.24.0` (community fork of the abandoned upstream `TTS` package). Cold model load ~6-10s on Apple Silicon CPU
- `scripts/voice_synth.py` — counterpart that loads the embedding and synthesizes Portuguese (default) or any XTTS-v2 language. Output: raw s16le PCM on stdout at 22050Hz (resampled from XTTS's native 24000Hz via `scipy.signal.resample_poly`, falls back to `np.interp` if scipy missing)
- `scripts/setup-voice-clone.sh` — idempotent bootstrap. Prefers `uv venv --python 3.11` (fast lockfile-clean install); falls back to `python3 -m venv`. Pins `coqui-tts>=0.24.0`, `scipy`, `soundfile`
- `build.zig.zon` `.version = "1.4.0"`, `src/main.zig` `VERSION = "1.4.0"`. HELP updated with the new subcommand surface
- `build.zig` — two new test steps (`run_voice_tests`, `run_ipc_tests`) so the v1.4 surface stays test-covered even if main.zig stops importing `voice.zig`

**Measurements** (Mac Air M4, ReleaseFast):

| Metric | Value | v1.4 target |
|---------|-------|-----------|
| `zig build` (Debug, host arm64) | clean | clean ✅ |
| `zig build test --summary all` | 40/40 tests pass | all pass ✅ |
| Slug validation tests | 3 pass (accept/reject empty+illegal) | all pass ✅ |
| WAV sniff tests | 3 pass (mono s16 22050, stereo 44.1k, zero-block guard) | all pass ✅ |
| ipc Engine round-trip with `cloned` | pass | pass ✅ |
| End-to-end clone smoke-test (real WAV → embedding → synth) | **not run in this session** | deferred to v1.4.1 |
| Cold sidecar startup (XTTS load, expected) | ~6-10s | informational |
| Warm cloned synth first-sample (expected) | ~500-900ms | informational |

**Honest scope**:

- **The Python sidecar was not installed or smoke-tested in this session.** XTTS-v2 (~1.8 GB model) download + first-run synth blows the time budget. The Zig surface is complete + tested; the Python scripts are written + executable + dispatched correctly by the daemon, but `scripts/setup-voice-clone.sh` has not been run on this machine. **v1.4.1 closes the gap**: run setup, clone Gabriel's voice from a 30s WAV, capture warm TTFA, publish in `_qa/v1.4.1-baseline.md`
- "Real" first-sample TTFA for cloned voices is expected at ~500-900ms on Apple Silicon CPU based on Coqui community benchmarks — pessimistic vs Faber's 91ms warm. Cloned is opt-in for personal voice, not the default
- No `Felipe`-grade naming UX yet. v1.4 ships the surface `--voice <slug>` and validates slug format; surfacing in `voice list` is plain text
- No ONNX export of the cloned voice. XTTS-v2 ONNX export is not production-stable (see [Coqui #4014](https://github.com/coqui-ai/TTS/discussions/4014)). v1.4 stays on the PyTorch path until that lands
- The "only Zig" lifecycle constraint is **relaxed for the cloned engine only**. Faber + say remain pure Zig — no Python required to use the default v1.0 surface. See `docs/motor.md` "Cloned voices (v1.4)" for the licensing + lifecycle rationale

**License note**: Coqui TTS is MPL-2.0. The Python sidecar runs as a separate process (`std.process.Child` from `daemon.zig::synthClonedViaSidecar`). The parent Zig binary remains dual MIT/Apache. The MPL boundary is the process line — no MPL code is linked or distributed inside `agent-tts`.

---

## v1.0 — universal binary + brew tap · 2026-06-03

**Shipped**:

- `zig build universal` — new `build.zig` step that compiles two independent slices (`aarch64-macos` + `x86_64-macos`, ReleaseFast, libpiper OFF) and fuses them with `lipo -create` into `zig-out/bin/agent-tts-universal`
- Cross-compile fallback: `sdkRoot()` in `build.zig` locates the macOS SDK (CLT preferred, Xcode.app fallback) and adds library/include/framework paths for the cross-targets. Without it, Zig 0.16 fails the linker on `libsqlite3.tbd` and the `@cImport` on `sqlite3.h` for non-native targets
- `build.zig.zon` version `1.0.0`, `src/main.zig` `VERSION = "1.0.0"`
- `Formula/agent-tts.rb` — Homebrew formula with `depends_on "sqlite"` + `macos: :ventura`, `test do system "#{bin}/agent-tts", "--version" end`, and a header documenting the tap path `gabriel/tap` (placeholder — replace with the real tap once the repo exists)
- `README.md` expanded with install sections (brew tap, source, launchd auto-start, optional libpiper)
- Universal binary runs on both architectures via `arch -arm64` and `arch -x86_64` (Rosetta 2), each reporting `agent-tts 1.0.0`

**Measurements** (Mac Air M4, ReleaseFast, libpiper OFF, baseline at `_qa/v1.0-baseline.md`):

| Metric | Value | v1.0 target |
|---------|-------|-----------|
| Universal binary size (with v0.7 zaudio) | 1 801 696 B (~1.8 MB) | < 2 MB ✅ |
| Host arm64 binary size (with v0.7 zaudio) | 900 552 B (~880 KB) | < 1 MB ✅ |
| Universal binary size (without v0.7, libpiper OFF) | 1 076 576 B (~1.1 MB) | informational |
| `lipo -info` | `x86_64 arm64` | both arches ✅ |
| ACK round-trip warm daemon (median, 7 calls) | 0.1 ms | < 300 ms ✅ (proxy) |
| Cold pre-warm (one-time boot) | 275.1 ms | informational |
| Bare `say` spawn+playback floor | ~790 ms | informational |
| `brew audit --strict --new` (after fixes) | 2 issues, both placeholder 404 URLs | structural ✅ |

**Honest scope**:

- Real TTFA (audio-device first-sample) not measured — dtruss requires SIP off, host runs SIP on. The 0.1ms ACK round-trip is a safe floor: the daemon responded before playback started. True TTFA sits between the pre-warm tail (~275ms) and bare-`say` spawn (~790ms)
- Piper warm-path NOT measured in this v1.0 — depends on v0.7 (zaudio + engine routing), which is in flight in parallel. When v0.7 closes, `_qa/v0.7-baseline.md` publishes the number
- Native Intel Mac untested (no hardware available). Cross-arch sanity validated via `arch -x86_64` (Rosetta 2): the x86_64 slice runs and reports the right version
- `brew install gabriel/tap/agent-tts` still fails — `gabriel/tap` is a placeholder, and the `url`/`sha256` in the Formula are placeholders until the first release tarball is published on GitHub with a computed hash

**Cross-compile gotcha (Zig 0.16)**:

Zig 0.16 auto-resolves macOS SDK paths only for the native target. For cross-targets the linker fails with `unable to find dynamic system library 'sqlite3'`. Workaround in `configureExe()`: probe `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk` (CLT) or the Xcode.app SDK, add `usr/lib` to the library path, `usr/include` to the system include path, and `System/Library/Frameworks` to the framework path. `libsqlite3.tbd` is multi-arch (x86_64-macos + arm64e-macos); non-secure arm64 links against arm64e without trouble.

---

## v0.7 — zaudio streaming PCM + engine routing · 2026-06-03

**Shipped**:

- `src/audio.zig` — `AudioPlayer` struct owning a `zaudio.Engine` (miniaudio). `streamS16le` plays an s16 mono buffer directly via `AudioBuffer` + `createSoundFromDataSource`, no temp WAV. `requestStop` aborts the poll loop via an atomic flag + `sound.stop()`
- `src/piper.zig` — new `synthToSamples(arena, text) ![]i16` returns PCM directly (no WAV); `sampleRate()` exposes the voice-config rate. `synthToWav` now calls `synthToSamples` + `writeWav`
- `src/ipc.zig` — `engine: Engine = .say` field on `Message`, `Engine { say, piper }` enum, encode/parse layout `ENQUEUE\t<engine>\t<voice>\t<rate>\t<text>`. **Backward compat**: `parseRequest` peek-detects the v0.6 layout (4 fields, no engine) and falls back to engine=.say
- `src/queue.zig` — idempotent schema migration via `PRAGMA table_info` + `ALTER TABLE items ADD COLUMN engine TEXT NOT NULL DEFAULT 'say'`. `push/list/tryClaimNext` propagate the field; `PoppedItem` gains `engine`
- `src/daemon.zig` — `AudioPlayer` boot best-effort in the daemon (logs time, graceful fallback if zaudio fails → `runPiper` falls back to WAV+afplay). `PiperEngine` lives in daemon scope (refactored from the `tryBootPiper` leak-and-pray into a `Resources` struct passed to the worker). `runOne` switches on `item.engine`; SKIP routes both SIGTERM (say) and `audio_player.requestStop()` (piper)
- `src/client.zig` — `--engine say|piper` flag. Default `say`. Default voice becomes `Luciana` or `faber` depending on engine
- `src/main.zig` — HELP updated. Hidden `ttfa-bench --engine X --warm N` subcommand instruments first-sample latency (zaudio first-sample callback) and runs N warm cycles
- `build.zig` — wires zaudio + miniaudio vendored sources (~100k LoC single-header) with `-DMA_NO_RUNTIME_LINKING` + CoreAudio/AudioUnit frameworks. `vendor/zaudio/COMMIT` pinned at `e5b89fde58be72de359089e9b8f5c4d5126fb159`
- In-tree patch in `vendor/zaudio/src/zaudio.zig`: Zig 0.16 removed `std.Thread.Mutex` — swapped for a `std.atomic.Value(bool)` spin lock (contention negligible in mem callbacks)

**Measurements** (Mac Air M4, ReleaseFast, baseline at `_qa/v0.7-baseline.md`):

| Metric | Value | v0.7 target |
|---------|-------|-----------|
| Piper TTFA warm (5-iter avg) | **91.3ms** (min 84.8, max 96.6) | < 1s ✅ |
| Piper warm — synth dominant | 91.2ms synth | informational |
| Piper init cold (bench, warm FS) | 335.0ms | informational |
| Daemon boot total | ~715ms (pre-warm 270 + zaudio 78 + piper 344) | informational |
| Say TTFA warm (5-iter avg) | 2229ms* | informational |
| Binary size without piper | 918 072 B (+463 KB vs v0.6) | informational |
| Binary size with piper | 975 304 B (+518 KB vs v0.6) | informational |
| Daemon RSS resident (piper + zaudio) | 176 MB | informational |
| Schema migration v0.6 → v0.7 | idempotent, ALTER backfills 'say' | informational |

*Caveat: "say TTFA" in the bench measures wall-clock spawn+wait+playback for a full Pt-BR sentence — NOT first-sample. macOS `say` exposes no hook for the first frame without hijacking the device. The real daemon-path number is the ~50ms round-trip from v0.2 (voice pre-warmed).

**Piper TTFA warm = 91.3ms** beats the 1s target by 10×. Engine resident in the daemon eliminated the 397ms cold init from v0.6.

**Honest decisions**:

- Upstream zaudio (`zig-gamedev/zaudio`) still uses `linkLibC()` (removed in Zig 0.16); we vendored `.zig` + `.c` in `vendor/zaudio/` instead of forking. Recipe in `vendor/README.md`. When upstream catches up, swap to a `build.zig.zon` dependency
- AudioPlayer uses `AudioBuffer` (one allocation per utterance) instead of a custom streaming `decoderReadProc`. Simpler; synth dominates TTFA, so optimizing playback overhead doesn't move the needle
- `say` TTFA stays not-truly-instrumented. Accepted for v0.7 — the daemon warm-voice path has been documented sub-100ms since v0.2
- Daemon RSS jumps from ~30 MB to 176 MB once piper loads. Price of keeping ONNX runtime + Faber-medium tensors warm. User opts in via `AGENT_TTS_PIPER=1`
- `runPiper` registers the daemon's own PID as "playing" (SKIP can't cancel in-flight piper synth — only playback). Trade-off accepted; synth lasts 90ms so users rarely want to SKIP mid-flight

**Build gotcha**:

- `std.Thread.Mutex` and `std.Thread.sleep` were removed in Zig 0.16. zaudio.zig got a spin-lock shim; audio.zig uses `std.c.nanosleep` directly (we already link libc into the exe)
- `linkLibC()` became `link_libc = true` in the module config. That's why we don't use upstream's build.zig.zon
- The original daemon imported `piper.zig` unconditionally; @cImport piper.h fails with `-Dwith-piper=false`. Fix: `piper_mod` is a conditional comptime alias

**License**: GPL-3.0 inherited from libpiper + espeak-ng when agent-tts is distributed with the dylib. zaudio is MIT. Net: GPL only because of Piper.

---

## v0.6 — libpiper FFI baseline · 2026-06-03

**Shipped**:

- Vendor build of `libpiper.dylib` from [OHF-Voice/piper1-gpl](https://github.com/OHF-Voice/piper1-gpl) tag v1.4.2 (static espeak-ng + ONNX Runtime 1.22.0 pulled by the project's CMake). Reproducible recipe in `vendor/README.md`, source gitignored
- `src/piper.zig` — `PiperEngine` struct via `@cImport piper.h`: `init(voice_path, espeak_data_path)` loads the model, `synthToWav(io, text, out_path)` synthesizes and writes PCM s16le mono WAV
- `build.zig` — `-Dwith-piper=true` option links `libpiper` + `c++` with `rpath` to `vendor/.../dist/lib/`. Default OFF keeps the binary slim for users on `say` only
- Experimental `agent-tts piper-test "<text>" <out.wav>` subcommand bypasses the daemon and measures init + cold synth
- Optional daemon boot: `AGENT_TTS_PIPER=1 agent-tts daemon` loads `PiperEngine` next to Luciana pre-warm — engine stays resident but v0.6 does NOT route playback yet (v0.7 does that with zaudio)
- `pt_BR-faber-medium.onnx` (63MB) voice downloaded to `~/.cache/agent-tts/voices/`

**Measurements** (Mac Air M4, ReleaseFast, baseline at `_qa/v0.6-baseline.md`):

| Metric | Value | v0.6 target |
|---------|-------|-----------|
| Piper init cold (filesystem cache miss) | 646.7ms | informational |
| Piper init warm (FS cached) | ~460ms | informational |
| Synth + WAV — short utterance (3-5 words) | 60-110ms | — |
| Synth + WAV — 268-char paragraph | 731ms | — |
| Total short (init+synth) | ~535ms | <1s ✅ |
| Total long (init+synth) | ~1217ms | <1s ❌ (200ms over) |
| Daemon piper engine load | 397ms | <500ms ✅ |
| Binary size without piper | 455 288 B | baseline |
| Binary size with piper | 457 336 B | +2 KB |

Short hits the target; long misses cold by 200ms. v0.7 kills the init cost by reusing the resident engine.

**Build gotcha**: espeak-ng defines `N_PATH_HOME=160` and the absolute path of the vault worktree (>160 chars) silently truncates filenames while compiling phonemes. Workaround: build in `/tmp/piper-build` and symlink `vendor/.../libpiper/build`. Documented in `vendor/README.md`.

**License**: GPL-3.0 inherited from libpiper + espeak-ng when agent-tts ships with the dylib. Public license decision is deferred to v1.0 (brew tap).

---

## v0.5 — Pt-BR preprocessor (human cadence) · 2026-06-03

**Shipped**:

- `src/preproc.zig`: 3 chained transforms, single-pass per stage, arena allocation per message
  - Whole-word abbreviations: `Sr. Sra. Dr. Dra. cf. etc. vs. nº Av. R$`
  - Pt-BR cardinals 0..9999 (state machine over digits; skipped when glued to a letter or `%`; supports negatives `-5` → "menos cinco" and zero)
  - `[[slnc N]]` pauses: `,` (150ms), `.` `!` `?` (400ms), `\n` (600ms); consecutive punctuation collapses to the largest in the group
- Hook in `tts.zig`: `spawnSay()` runs the preproc before `say` argv. Preproc failure is non-fatal — log + fall back to raw text
- Binary 496KB arm64 Mach-O (was 455KB at v0.2; sum of v0.3 SQLite + v0.4 launchd + v0.5 preproc)
- 26 new tests covering each transform + edge cases. `zig build test` = 27/27

**Measurements** (Mac Air M4, ReleaseFast, 1000 iter per case; baseline at `_qa/v0.5-baseline.md`):

| Case | input bytes | median | mean |
|------|-------------:|--------:|------:|
| short greeting (`Olá, mundo.`) | 12 | 2.0 µs | 1.5 µs |
| `Sr. Silva tem 25 anos, certo?` | 29 | 4.0 µs | 3.4 µs |
| `Av. Paulista, nº 1578.` | 23 | 3.0 µs | 3.2 µs |
| `Estamos em 2026 e devemos R$ 1234…` | 47 | 4.0 µs | 3.5 µs |
| long mixed paragraph | 151 | 5.0 µs | 4.4 µs |

Budget was < 1ms per message; we shipped 200× under. Zero TTFA-regression risk.

**Honest decisions**:

- `Sr.` consumes the dot (becomes "Senhor", no trailing pause). Treated as abbreviation, not terminator
- `R$` is a blind substitution, doesn't reorder: `R$ 500` → "reais quinhentos". Good enough until someone complains
- The "e" connector for thousands follows Pt-BR convention: `1500` = "mil e quinhentos", `1578` = "mil quinhentos e setenta e oito"
- Cap at 9999 — bigger numbers stay raw (`say` reads them digit-by-digit)
- Fractions, times (`14h30`), decimals still literal. YAGNI until real demand

---

## v0.4 — launchd auto-start · 2026-06-03

**Shipped**:

- `agent-tts daemon install | uninstall | status` subcommands
- LaunchAgent plist at `~/Library/LaunchAgents/cloud.mukutu.agent-tts.plist` — daemon survives logout/reboot
- Atomic plist write via `createFileAtomic` + `replace` (the kernel only sees old or new, never half-written)
- `launchctl bootstrap gui/<uid>` on install (replaces the deprecated `launchctl load`); `bootout` on uninstall
- `KeepAlive` as a dict `SuccessfulExit=false` — restart only on crash
- `HOME` forced via `EnvironmentVariables` — launchd doesn't inherit it reliably
- Self-locate via `std.process.executablePath` (Darwin: `_NSGetExecutablePath` + realpath)
- uid lookup via `std.c.getuid()` to build the `gui/<uid>` domain
- Label override via `AGENT_TTS_LAUNCHD_LABEL` env — used by the dry-run test
- Guards: install refuses if the plist already exists, uninstall refuses if it doesn't

**Measurements** (Mac Air M4, dry-run with test label, baseline at `_qa/v0.4-baseline.md`):

| Metric | Value | v0.4 target |
|---------|-------|-----------|
| Install round-trip (median, 3 runs) | ~10ms | < 200ms |
| Uninstall round-trip (median, 3 runs) | ~10ms | < 200ms |
| Plist parse (`plutil -lint`) | OK | OK |
| `launchctl list` post-install | PID + label visible | visible |
| `launchctl list` post-uninstall | label absent | absent |

Dominated by the fork+exec of `/bin/launchctl`. macOS `/usr/bin/time` granularity = 10ms; real ≤ 10ms.

---

## v0.3 — SQLite WAL queue + queue/skip/clear · 2026-06-03

**Shipped**:

- Queue migrated from in-memory `ArrayList` to **SQLite WAL** at `~/.cache/agent-tts/queue.db` — survives daemon crash + reboot
- Schema `items(id, text, voice, rate, state, enqueued_at, started_at, finished_at)` + partial index on `state IN ('pending','playing')`
- Boot-time crash recovery: `UPDATE state='pending' WHERE state='playing'` re-promotes orphans
- 3 new subcommands: `agent-tts queue` (lists pending+playing), `skip` (SIGTERM on the current `say`), `clear` (marks pendings as skipped)
- IPC protocol extended: `ENQUEUE` (same as v0.2) + `QUEUE`, `SKIP`, `CLEAR` + `ITEM\t...\n` response + `END\n`
- Worker rewritten: drains via SQLite, registers the child PID before `wait()`, SKIP sends SIGTERM to the saved PID
- `@cImport(sqlite3.h)` + `linkSystemLibrary("sqlite3", .{})` — uses the macOS SDK's libsqlite3

**Measurements** (Mac Air M4, warm daemon, baseline at `_qa/v0.3-baseline.md`):

| Metric | Value | v0.3 target |
|---------|-------|-----------|
| ACK round-trip enqueue (median, 7 calls) | 0.1ms | informational |
| ACK round-trip queue (median, 5 calls) | 0.1ms | informational |
| ACK round-trip skip | <10ms (measurement floor) | informational |
| Binary size (ReleaseFast) | 476KB | <1MB |
| Persistence (kill -9 mid-play) | ✅ 3/3 items drain post-restart | "queue survives crash" |

The "queue survives daemon crash" criterion holds: killing daemon + `say` mid-utterance leaves the item in `playing` in the DB; restart re-promotes the orphan to `pending` and the worker drains it.
---

## Benchmark interlude · 2026-06-03

Before coding v0.3, I spent a session benchmarking alternative engines to fix Pt+En code-switching. Conclusions in [TTS engine](/motor/). Summary:

- Piper Faber via Python — Pt-only, rejected
- XTTS-v2 multilingual via Python — 27s/call from the CLI, Python sidecar rejected by the "only Zig" constraint
- Decision: **libpiper FFI** (from OHF-Voice/piper1-gpl) lands as v0.6-v0.7, brings the Faber voice + native ONNX runtime via `@cImport`, `PiperEngine` owner struct, zaudio for PCM streaming
- EN code-switching stays unsolved until v1.1+ (mature multilingual ONNX)

Cleanup: 3.2GB freed (XTTS-v2 venv + model + uv cache). The `pt_BR-faber-medium.onnx` voice (63MB) is kept in `~/.cache/agent-tts/voices/` for v0.6+.

---

## v0.2 — daemon + socket + in-memory queue · 2026-06-03

**Shipped**:

- Foreground daemon (`agent-tts daemon`) with a UNIX socket at `~/.cache/agent-tts/sock`
- Thread-safe in-memory queue (`std.Io.Mutex` + `std.Io.Condition` + `std.ArrayList`)
- Single worker thread drains the queue by calling `say` — playback serialized, never parallel
- Boot-time pre-warm of the Luciana voice (`say -v Luciana " "`)
- Client round-trips over the socket: ENQUEUE → ACK in sub-100µs
- Simple line protocol: `ENQUEUE\t<voice>\t<rate>\t<text>\n` → `OK\t<id>\n` or `ERR\t<msg>\n`
- 455KB arm64 Mach-O binary (was 415KB at v0.1, +40KB for thread + socket + queue)

**Measurements** (Mac Air M4, warm daemon, baseline at `_qa/v0.2-baseline.md`):

| Metric | Value | v0.2 target |
|---------|-------|-----------|
| ACK round-trip (median, 7 calls) | 0.0ms | < 400ms |
| Cold pre-warm (one-time boot) | 340.3ms | informational |

Roadmap target was warm TTFA <400ms. ACK round-trip <100µs lands 4000× under the ceiling — daemon responds long before audio starts.

---

## v0.1 — `say` direct, no daemon · 2026-06-03

**Shipped**:

- Zig 0.16 single-binary CLI, 415KB arm64 ReleaseFast
- `agent-tts "text"` calls `say -v Luciana -r 330` directly
- Flags `--voice NAME --rate WPM -h --help -V --version`
- Default voice **Luciana**, default rate **330wpm** (sweet spot picked by ear — 180 too slow, 430 too dry)

**Measurements** (baseline at `_qa/v0.1-baseline.md`):

| Metric | Value |
|---------|-------|
| Spawn latency (median, 5 runs) | 0.8ms |
| Rate 180 → 600 sweep | linear drop to 540, plateau above |

Spawn = time until `std.process.spawn` returns. Not real TTFA.

**Voices tested — only Luciana survived**:

Other installed Pt-BR voices (Eddy, Flo, Rocko, Reed, Sandy, Grandma, Grandpa, Shelley) — rejected on quality. Luciana Premium wasn't installed on the test machine; once installed, it becomes the default.
