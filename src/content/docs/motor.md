---
title: TTS engine
description: Pt-BR engine comparison and why `say` Premium Luciana wins in v1.0.
---

## TL;DR

**v1.0** pick: `say` Luciana wins — TTFA + size + native Neural Engine. The decision is revisited in **v1.1+** because agents speak Pt-BR with English terms ("GitHub Actions", "Coolify deploy") and monolingual `say` mispronounces them.

**v1.1+ plan**: multilingual engine via Python sidecar. **XTTS-v2** (Coqui) picked for native Pt+En code-switching plus top neural quality. Costs ~3GB on disk and needs a Python sidecar (the model must stay resident). Decision made 2026-06-03 after benchmarking Piper Faber (Pt-only, failed on EN) and XTTS-v2 CLI (top quality but 27s/call from the CLI due to model reload).

## Comparison

Primary criterion is **time-to-first-audio**. Secondary criterion is disk size (Mac Air M4 with a small SSD).

| Engine | Extra size | Typical TTFA | Pt-BR quality | Cost | Offline |
|-------|---------------|-------------|------------------|-------|---------|
| **macOS `say` Premium** | 0 in the binary, ~200MB system-side (Premium voice) | **< 200ms** warm | Good (Luciana/Felipe Premium) | Free | Yes |
| Piper (`pt_BR-faber-medium`) | ~63MB voice + ~10MB runtime | ~100ms | OK, robotic | Free (MIT) | Yes |
| Kokoro | ~80MB | ~200ms | Pt-BR limited, EN fallback | Free (Apache) | Yes |
| Coqui XTTS-v2 | ~2GB+ | ~500ms-1s first sentence | Excellent, cloneable | Free | Yes |
| ElevenLabs | 0 local | 200-800ms + network RTT | Excellent | Paid + network | No |

## Benchmark 2026-06-03 + v1.1+ decision

Driver for the review: agents speak Pt-BR with English terms ("GitHub Actions", "Coolify deploy") and monolingual `say` mispronounces them. Tested: Piper Faber (Pt-only, Python via uvx) and multilingual XTTS-v2.

| Engine | Footprint | Real TTFA (agent UX) | Code-switch | Verdict |
|--------|-----------|----------------------|-------------|----------|
| say Luciana | 0 | ~50ms (warm daemon) | bad | keep in v1.0 |
| Piper Faber via uvx | 250MB | ~650ms | bad | rejected (Pt-only + python dep) |
| XTTS-v2 CLI Python | 3GB | 27s/call (Python reload) | good | rejected (CLI unviable, Python sidecar blocked by "only Zig") |

Disk before: 8.4GB free. XTTS reserved 3GB. Cleanup after the decision freed it all.

### v1.1+ plan locked: **libpiper FFI**

Self-imposed constraint: **only Zig** owns the lifecycle. No Python sidecar. Survey of Zig OSS (Ghostty, zml, matklad notes, zaudio):

- **libpiper** (from [OHF-Voice/piper1-gpl](https://github.com/OHF-Voice/piper1-gpl), 4.3k★, GPL) — the only clean, maintained C API with a Pt-BR voice. Built via CMake, which pulls onnxruntime + espeak-ng. `@cImport piper.h` + link `libpiper.dylib`
- **No mature Zig port** of Piper exists. The Zig ONNX Runtime wrapper ([recursiveGecko/onnxruntime.zig](https://github.com/recursiveGecko/onnxruntime.zig), 34★) is incomplete and has no CoreML provider
- **zaudio** ([zig-gamedev/zaudio](https://github.com/zig-gamedev/zaudio), miniaudio wrapper) — PCM streaming playback with sub-1s TTFA, callback-driven, no temp WAV
- **Ghostty-style architecture**: long-lived `PiperEngine` struct, init at daemon boot with `errdefer` for partial unwind, deinit on shutdown. Per-utterance `ArenaAllocator` reset between calls. Root allocator = GPA for debug + leak check
- **Accepted gap**: Faber-medium voice is Pt-only, EN code-switching still fails. Fix later with a multilingual ONNX voice once available (XTTS ONNX export isn't production-ready per [Coqui discussion #4014](https://github.com/coqui-ai/TTS/discussions/4014))
- **License**: GPL inherited from libpiper. agent-tts becomes GPL in v1.1+ if it ships the binary. Accepted.

## Why `say` Premium wins

1. **Zero weight in the binary**. Voice lives in `/System/Library/Speech/Voices/`. Keeps the small-SSD target
2. **Apple Neural Engine** is used natively — Luciana Premium is neural, not concatenative
3. **Consistent TTFA**: daemon pre-warms once (`say -v Luciana ""`), subsequent calls < 200ms
4. **Acceptable Pt-BR quality** for agent-internal use — we're not shipping audiobooks
5. **Stable API**: `say` has existed since Mac OS X 10.3, it isn't going to move
6. **Native SSML-like support**: `[[rate 200]]`, `[[slnc 400]]`, `[[volm 0.8]]`

## Why the others lose in v1.0

### Piper
Good engine. The main Pt-BR voice (`faber-medium`) is OK but robotic. Worth keeping as an offline Linux fallback or in case Apple ever drops `say`. **v1.1+**.

### Kokoro
Pt-BR isn't a first-class target for the project — it falls back to EN with an accent. Rejected.

### Coqui XTTS-v2
Excellent quality, but 2GB+ blows the SSD budget. Cold TTFA above 1s. Plausible if the goal ever shifts to "clone Gabriel's voice".

### ElevenLabs
Network-dependent latency destroys the KPI. Per-message cost kills casual agent use. Rejected.

## Default voice

`Luciana (Premium)`. User installs via:

```
System Settings → Accessibility → Spoken Content
→ System Voice → Manage Voices
→ Portuguese (Brazil) → Luciana (Premium) → Download
```

Daemon detects it on first run. If absent → prints the exact instruction + link and degrades to the system's default voice.

Male alternative: `Felipe (Premium)`. Same quality.

## Per-call override

```bash
agent-tts --voice "Felipe (Premium)" "Text."
agent-tts --rate 220 "Faster."
```

Persistent config in `~/.config/agent-tts/config.json` (future v0.5+).
