# docsync-landing — lead time

Agent: `agent-tts/docs-landing` (sync landing + whats-next + roadmap + README to v1.10.13).

| Marker | Value |
|---|---|
| `agent_start_ts` (unix) | 1780579267 |
| `agent_end_ts` (unix)   | 1780579560 |
| Elapsed                 | 293 s (~4 min 53 s) |

## Scope

- `src/content/docs/index.mdx` — hero tagline + MCP 13-tool count + comparison table rows (postfx, per-call knobs, tech-report, cadence, logging) + 4 new feature cards.
- `src/content/docs/whats-next.md` — TL;DR refreshed to "18 base + 13 patches" + current head `v1.10.13`; the v1.10.4 → v1.10.13 entries were already present in this worktree, only the TL;DR + frontmatter description were stale.
- `src/content/docs/roadmap.md` — TL;DR retitled to `v0.1 → v1.10.13`; 4 new KPI rows (postfx warm chunks, watchdog kill at deadline, concurrent enqueue drain, structured-log overhead); closing "What's next" paragraph updated. Shipped table already covered v1.10.4 → v1.10.13.
- `README.md` (repo root) — new "What's new — v1.10.13" mini-section at top; comparison table extended with postfx / per-call knobs / tech-report / pause-resume-replay / MCP 13-tool count / structured logging rows; install section now includes the `/opt/homebrew/share/agent-tts` symlink convention from v1.10.5; quick-start gains tech / postfx / knob / history / clone / log examples; Status table rewritten to span v0.1 → v1.10.13; Roadmap section retargeted to v1.11+.

## Gates

- `npm run build` → green (10 pages, ~4 s, Pagefind indexed 9 pages, 4746 words).
- Latest version mentioned across the four files: `v1.10.13` (confirmed via `grep -RnE "v1\\.10\\.([0-9]+)"`).
- `dist/index.html`, `dist/roadmap/index.html`, `dist/whats-next/index.html` rendered with v1.10.13 references; no `{{` or `${` template tags leaked into HTML.

## TODOs left for other docs agents

None. All four scope files updated within scope; no `<!-- TODO docs-arch -->` / `<!-- TODO docs-feature -->` comments needed.
