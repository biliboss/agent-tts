---
title: TTS engine
description: Piper Faber wins as the v1.0 default. macOS say Luciana is the offline-always fallback. Comparison + decision history.
---

## TL;DR

**v1.0 default**: **libpiper Faber** (neural, Pt-BR). Warm synth ~91 ms, cold engine load ~400 ms paid once at daemon boot. Single-binary, no Python.

**Fallback**: macOS `say -v Luciana`. Works even when piper is not built in. Selected with `--engine say`.

Both are offline, both are free, both ship in the same Zig binary.

| | Piper Faber (default) | macOS `say` (fallback) |
|---|---|---|
| Engine type | Neural (ONNX) | Concatenative + ANE |
| Pt-BR quality | Top neural | Solid system voice |
| Warm synth | **~91 ms** | spawn 0.8 ms + playback |
| Cold engine load | ~400 ms once at daemon boot | 0 |
| Disk extra | 63 MB voice ONNX + ~34 MB dylibs | 0 (system) |
| Binary delta | +2 KB Zig + dylib payload | 0 |
| Code-switch EN | Mispronounces ("GitHub Actions") | Mispronounces |
| License | GPL-3.0 inherits when linked | Free (system) |

Both engines mispronounce English terms today — that is the headline gap addressed in v1.1.

## Decision history

Before v0.6 the plan called for `say` Luciana as the v1.0 default and an optional Coqui XTTS-v2 Python sidecar for the neural path. That plan was rejected on 2026-06-03 for two reasons:

- **Pt-only Piper Faber** failed code-switch (rejected).
- **XTTS-v2 via Python sidecar** worked but violated the "only Zig" lifecycle constraint.

The accepted alternative landed in v0.6: link **libpiper** from [OHF-Voice/piper1-gpl](https://github.com/OHF-Voice/piper1-gpl) via `@cImport piper.h`. That made Piper Faber a single-binary engine — no Python, no sidecar. v0.7 then made it the default, swapping `say` to the fallback slot.

## Comparison vs alternatives

Primary criterion is **time-to-first-audio** (TTFA). Secondary criterion is disk size (Mac Air M4 with a small SSD).

| Engine | Extra size | Typical warm TTFA | Pt-BR quality | Cost | Offline |
|---|---|---|---|---|---|
| **Piper Faber (libpiper FFI)** | ~63 MB voice + ~34 MB dylibs | **~91 ms warm** | Top neural Pt-BR | Free (GPL) | Yes |
| **macOS `say` Premium** | 0 in binary, ~200 MB system-side | < 200 ms warm | Good (Luciana/Felipe Premium) | Free | Yes |
| Coqui XTTS-v2 | ~2 GB+ | ~500 ms - 1 s first sentence | Excellent, cloneable | Free | Yes |
| Kokoro | ~80 MB | ~200 ms | Pt-BR limited, EN fallback | Free | Yes |
| ElevenLabs | 0 local | 200-800 ms + network RTT | Excellent | Paid + network | No |

## Why Piper Faber wins as default

1. **Neural quality without Python.** Single Zig binary, no venv to bless.
2. **Resident engine in the daemon.** The ~400 ms cold load is paid once at boot; every subsequent synth is ~90 ms.
3. **zaudio streaming PCM.** No WAV temp file, no `afplay` spawn — playback starts the moment the buffer is ready.
4. **Predictable footprint.** 63 MB voice + 34 MB dylibs, downloaded once via `scripts/fetch-voice.sh` + `scripts/build-libpiper.sh`.

## Why `say` Luciana wins as fallback

1. **Zero binary cost.** The voice lives in `/System/Library/Speech/Voices/`. Keeps the no-piper binary under 1 MB.
2. **Apple Neural Engine.** Luciana Premium is neural under the hood — not pure concatenative.
3. **Always works.** Available on every macOS install. No vendor build, no ONNX, no download.
4. **Stable API.** `say` has existed since Mac OS X 10.3.
5. **Native SSML-like cues**: `[[rate 200]]`, `[[slnc 400]]`, `[[volm 0.8]]`.

## Why the others lose for v1.0

### Coqui XTTS-v2

Excellent quality, but 2 GB+ breaks the SSD goal and the "only Zig" constraint. ONNX export is not production-stable yet (see [Coqui discussion #4014](https://github.com/coqui-ai/TTS/discussions/4014)). Revisit when ONNX multilingual stabilizes — that is the v1.1 path.

### Kokoro

Pt-BR is not a primary target. EN fallback has an accent. Rejected.

### ElevenLabs

Network-dependent latency wrecks the KPI. Per-message cost kills casual agent use. Offline-only is non-negotiable. Rejected.

## Voice setup

`Luciana (Premium)`. Install via:

```
System Settings → Accessibility → Spoken Content
→ System Voice → Manage Voices
→ Portuguese (Brazil) → Luciana (Premium) → Download
```

The daemon detects it on first run. If missing, it prints the exact path above and falls back to the default system voice.

Masculine alternative: `Felipe (Premium)`. Same quality.

Piper Faber model is downloaded once by `scripts/fetch-voice.sh` to `~/.cache/agent-tts/voices/pt_BR-faber-medium.onnx` (~63 MB).

## Override per call

```bash
agent-tts "Texto."                              # default piper Faber
agent-tts --engine say "Texto."                 # macOS say (fallback)
agent-tts --voice "Felipe (Premium)" "Texto."   # specific say voice
agent-tts --rate 220 "Mais rápido."             # WPM (say only — piper ignores)
```

Persistent config in `~/.config/agent-tts/config.json` planned for v1.1.

## Cloned voices (v1.4)

v1.4 adds a **third engine**: `cloned`. Selected automatically when `--voice <slug>` resolves to a directory under `~/.cache/agent-tts/voices/<slug>/` produced by `agent-tts voice clone`.

```bash
agent-tts voice clone --sample me-reading.wav --name gabriel
agent-tts --voice gabriel "Deploy concluído."
```

**The cloned engine is not pure Zig.** Coqui XTTS-v2 (the only credible local Pt-BR cloner) is a 2 GB PyTorch model with no production-stable ONNX export today. Reimplementing XTTS in Zig is not on the table — and embedding the model in a Zig binary breaks the SSD goal anyway.

So v1.4 **relaxes the "only Zig" lifecycle constraint, but only for the cloned engine**. Faber + say still work without Python:

| Engine | Runtime | Python required? |
|---|---|---|
| `say` (Luciana) | macOS system | no |
| `piper` (Faber) | libpiper FFI (Zig binary) | no |
| `cloned` (custom) | Python sidecar via `std.process.Child` | **yes** |

**Process line is the licensing wall.** Coqui TTS is MPL-2.0. The sidecar runs as a separate process spawned from `daemon.zig::synthClonedViaSidecar`. The parent Zig binary stays dual MIT/Apache — no MPL code is linked or distributed inside `agent-tts`.

**Sidecar protocol** (kept boring):

```
voice_synth.py --embedding <path.npz> --rate 22050 [--lang pt]
  ← text on stdin
  → raw s16le mono PCM on stdout at the requested rate
```

The daemon drains stdout into a buffer, feeds it to the same `AudioPlayer.streamS16le` path Faber uses. Fallback chain on sidecar failure: piper Faber when loaded, else `say` Luciana.

**Why this isn't the default.** Cold startup of XTTS-v2 on Apple Silicon CPU is ~6-10s and warm first-sample is ~500-900ms — pessimistic vs Faber's 91ms. Cloned is opt-in for personal voice, not the snappy default.

See [Changelog v1.4](/changelog/#v14--voice-cloning--2026-06-03) for the install + measurement story.

## Open gap: code-switching EN

`GitHub Actions` is pronounced as Portuguese phonemes today by both Piper Faber and `say`. This is the headline driver for v1.1 — see [What's next](/whats-next/).
