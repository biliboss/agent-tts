---
title: MCP server
description: Native Claude Code / Cursor / Cline voice — agent-tts speaks via stdio JSON-RPC since v1.5.
---

## TL;DR

`agent-tts mcp` runs a stdio JSON-RPC 2.0 server that exposes the daemon to any [Model Context Protocol](https://modelcontextprotocol.io) client. Claude Code, Cursor, Cline, Continue — same wire, same **13 tools** (v1.10.10 adds the `postfx` enum param to `say` / `synth_voice_test` and doubles `tech_profile_search` to a 4×2=8 knob×postfx matrix). No shell-out, no permission prompt per call, no stdout parsing.

Bundled in the same Zig binary as the CLI and the daemon. `+115 KB` over v1.0. Tools only — `prompts/`, `resources/`, `sampling/` are deferred.

## Install

Recommended path — let the installer merge into `~/.claude.json`:

```bash
./scripts/install-mcp.sh
```

The installer is idempotent, backs up `~/.claude.json` before writing, and refuses to touch a JSON file that does not parse as an object.

Manual path — paste this block into `~/.claude.json` (or your MCP client's equivalent):

```json
{
  "mcpServers": {
    "agent-tts": {
      "command": "/opt/homebrew/bin/agent-tts",
      "args": ["mcp"]
    }
  }
}
```

Then restart Claude Code (or your client) so it picks up the new server. Verify:

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | agent-tts mcp
```

You should get back a single JSON line listing the 13 tools.

## The 13 tools

| Tool | Args | Returns |
|------|------|---------|
| `say` | `{ text, engine?, voice?, rate?, ssml?, length_scale?, noise_scale?, noise_w?, tech?, comma_pause_ms?, sentence_pause_ms?, newline_pause_ms?, speaker_id?, postfx? }` | `{ id }` |
| `queue` | `{}` | `{ items: [...] }` |
| `skip` | `{ id? }` (ignored in v1.5) | `{ skipped_id }` |
| `clear` | `{}` | `{ cleared_count }` |
| `voices` | `{}` | `{ voices: [...] }` |
| `say_stream` (v1.7+) | `{ stream_id, chunk, final?, engine?, voice?, rate? }` | `{ enqueued_count, final }` |
| `pause` (v1.10.2+) | `{}` | `{ paused_id }` (0 = nothing playing) |
| `resume` (v1.10.2+) | `{}` | `{ resumed_id }` (0 = not paused) |
| `replay` (v1.10.2+) | `{ id }` | `{ new_id }` (0 = item not found) |
| `history` (v1.10.2+) | `{ limit? }` (1..100, default 20) | `{ items: [{id,state,engine,voice,rate,finished_at,text}, ...] }` |
| `synth_voice_test` (v1.10.7+) | `{ text, length_scale?, noise_scale?, noise_w?, tech?, *_pause_ms?, speaker_id?, postfx? }` | `{ id, …resolved knobs…, postfx }` |
| `voice_knob_search` (v1.10.8+) | `{ text, variants: [{...knobs, comment?}], max_variants? }` | `{ items: [{id, comment, knobs}], truncated }` |
| `tech_profile_search` (v1.10.10+) | `{ text }` | `{ items: [{id, name, postfx, comment, knobs}], count: 8 }` — fixed 4×2 matrix (tight-narrator / stock-tech / broadcast / expressive) × (postfx=off / postfx=tech) so the caller A/Bs both knob AND post-fx in one round-trip |

### v1.10.10 — `postfx` on `say` and `synth_voice_test`

Both tools accept an optional `postfx` enum routing the synth PCM through an ffmpeg subprocess (RNNoise + 4-band EQ + de-esser + 2:1 compressor) before zaudio plays it. Values: `off` (default) / `clean` / `tech` / `broadcast`. See [motor → Audio post-processing](/agent-tts/motor/#audio-post-processing-v11010) for the exact filter graphs and the `brew install ffmpeg` + RNNoise model install. ffmpeg must be on `PATH` (or at `$AGENT_TTS_FFMPEG_PATH`); when missing the chain falls back to dry PCM silently.

`tech_profile_search` now enqueues each of its 4 curated knob bundles twice — once dry, once with `postfx=tech` — so a single MCP call gives Claude Code 8 IDs covering the full (knob × postfx) hyperplane.

### v1.10.7 — Per-call Piper knobs on `say`

The `say` tool gains three optional numeric parameters that override Piper inference per call. Each is honored only when the daemon routes to `engine=piper` (or implicitly via voice resolution):

| Parameter | Range | Effect |
|---|---|---|
| `length_scale` | 0.1 – 3.0 | <1 = faster; >1 = slower. Overrides `<prosody rate>` only outside SSML markup. |
| `noise_scale` | 0 – 2 | Higher = more prosody variation. Faber sweet spot ≈0.667. |
| `noise_w` | 0 – 2 | Higher = more pronunciation variation. Faber sweet spot ≈0.8. |

Use `synth_voice_test` as an A/B helper — it always routes to Faber and echoes the resolved knobs in the response so an agent can record the experiment.

### v1.10.8 — Tech mode + max knobs

Five more optional params land on `say` + `synth_voice_test`:

| Parameter | Range | Effect |
|---|---|---|
| `tech` | boolean | Run the tech-report glossary (acronyms spelled, units expanded). |
| `comma_pause_ms` | 0 – 5000 | Override `[[slnc N]]` after `,` (default 150). 0 = use default. |
| `sentence_pause_ms` | 0 – 5000 | Override `[[slnc N]]` after .!? (default 400). Tech profile uses 500. |
| `newline_pause_ms` | 0 – 5000 | Override `[[slnc N]]` after newline (default 600). |
| `speaker_id` | -1 – 1000 | Piper multi-speaker integer. -1 = voice default. Faber is single-speaker. |

The new **`voice_knob_search`** tool lets an agent scan an N-variant knob hyperplane in **one MCP round-trip** instead of N sequential `tools/call`s. Each variant carries any subset of the per-call knobs plus a free-form `comment`. Cap: 16 variants.

Sample:

```json
→ {"jsonrpc":"2.0","id":7,"method":"tools/call","params":{
    "name":"voice_knob_search",
    "arguments":{
      "text":"API rodou em 250 ms.",
      "variants":[
        {"length_scale":0.95,"noise_scale":0.667,"noise_w":0.85,"tech":true,"comment":"warm-tech"},
        {"length_scale":1.05,"noise_scale":0.8,"noise_w":1.0,"comment":"slow-baseline"},
        {"length_scale":0.85,"noise_scale":0.5,"noise_w":0.7,"tech":true,"sentence_pause_ms":600,"comment":"fast-paused"}
      ]
    }
  }}
← {"jsonrpc":"2.0","id":7,"result":{"content":[{"type":"text","text":"{\"items\":[{\"id\":\"145\",\"comment\":\"warm-tech\",\"knobs\":{...}}, ...],\"truncated\":false}"}],"isError":false}}
```

Each tool is a thin shim over the same UNIX socket the CLI uses. No new daemon code beyond the v1.10.2 ops the four new tools wrap. Tool errors (daemon down, malformed args) come back as `isError: true` MCP responses with a human-readable text block — the JSON-RPC envelope only errors on parse failures (`-32700`) or unknown methods (`-32601`).

## JSON-RPC samples

`initialize` — first call from the client, response carries server capabilities:

```json
→ {"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
← {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{"listChanged":false}},"serverInfo":{"name":"agent-tts","version":"1.5.0"}}}
```

`tools/list` — enumerate the 5 tools:

```json
→ {"jsonrpc":"2.0","id":2,"method":"tools/list"}
← {"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"say","description":"Enqueue Pt-BR TTS on the running daemon. Returns the queue item id.","inputSchema":{"type":"object","properties":{"text":{"type":"string"}, "engine":{"type":"string","enum":["say","piper"]}, "voice":{"type":"string"}, "rate":{"type":"integer"}}, "required":["text"]}}, ...]}}
```

`tools/call → say`:

```json
→ {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"say","arguments":{"text":"Deploy concluído","engine":"piper"}}}
← {"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"{\"id\":\"42\"}"}],"isError":false}}
```

`tools/call → queue`:

```json
→ {"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"queue","arguments":{}}}
← {"jsonrpc":"2.0","id":4,"result":{"content":[{"type":"text","text":"{\"items\":[{\"id\":\"42\",\"state\":\"playing\",\"engine\":\"piper\",\"voice\":\"faber\",\"rate\":\"330\",\"text\":\"Deploy concluído\"}]}"}],"isError":false}}
```

`tools/call → voices`:

```json
→ {"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"voices","arguments":{}}}
← {"jsonrpc":"2.0","id":5,"result":{"content":[{"type":"text","text":"{\"voices\":[{\"engine\":\"say\",\"name\":\"Luciana\",...},{\"engine\":\"piper\",\"name\":\"pt_BR-faber-medium\",...}]}"}],"isError":false}}
```

Tool error path — daemon not running:

```json
→ {"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"queue","arguments":{}}}
← {"jsonrpc":"2.0","id":6,"result":{"content":[{"type":"text","text":"daemon not running"}],"isError":true}}
```

## Claude Code walkthrough

1. Build + install agent-tts:
   ```bash
   zig build -Doptimize=ReleaseFast
   cp zig-out/bin/agent-tts /opt/homebrew/bin/
   agent-tts daemon install   # autostart at login
   ```
2. Register the MCP server:
   ```bash
   ./scripts/install-mcp.sh
   ```
3. Restart Claude Code. New tools `say`, `queue`, `skip`, `clear`, `voices` show up under the `agent-tts` server.
4. Ask Claude to use one: *"Use the say tool to read this paragraph in Portuguese."* No shell prompt, no permission dance per call.

The daemon does the actual synthesis — the MCP server is a stateless bridge. Killing the MCP process between calls is fine; Claude Code spawns one per session.

## Honest deferrals

| Capability | Status | Why |
|------------|--------|-----|
| `prompts/*` | not implemented | voice agents do not need prompt templates |
| `resources/*` | not implemented | the daemon owns no addressable content |
| `sampling/*` | not implemented | nothing in agent-tts asks the LLM to think |
| `logging/*` | not implemented | daemon logs land in `~/.cache/agent-tts/daemon.*.log` already |
| `notifications/tools/list_changed` | declared off (`listChanged: false`) | tool list never changes mid-session |
| `skip(id)` | argument accepted, ignored | the daemon's SKIP only targets the head; v1.6 will route by id |
| `voices` enumerating all installed `say` voices | hardcoded to Luciana + Felipe | `say -v ?` would cost a process per call; v1.6 |
| End-to-end test against a real Claude Code | not measured | scaffolded via `echo \| agent-tts mcp` smoke tests; full client validation deferred |

## Related

- [Architecture](/agent-tts/arquitetura/) — MCP server slots into "Components"
- [Changelog](/agent-tts/changelog/) — v1.5 entry has the install snippet and the binary-size delta
- [MCP spec](https://modelcontextprotocol.io/specification/2024-11-05) — the protocol agent-tts speaks
