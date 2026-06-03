---
title: Changelog
description: Marcos entregues e medições reais por versão.
---

## TL;DR

Por marco: o que entregou, como medimos, o que ficou para o próximo. KPI único é TTFA. Sem número publicado, marco não fechou.

---

## Benchmark interlúdio · 2026-06-03

Antes de codar v0.3, gastei uma sessão benchmarkando motores alternativos pra resolver code-switching Pt+En. Conclusões em [Motor TTS](/motor/). Resumo:

- Piper Faber via Python — mono Pt, rejeitado
- XTTS-v2 multilingual via Python — 27s/call CLI, sidecar Python rejeitado pela restrição "only Zig"
- Decisão: **libpiper FFI** (de OHF-Voice/piper1-gpl) entra como v0.6-v0.7, traz voz Faber + ONNX runtime nativo via `@cImport`, struct `PiperEngine` owner, zaudio pra streaming PCM
- Code-switching EN fica não-resolvido até v1.1+ (ONNX multilingual maduro)

Limpeza: 3.2GB liberados (XTTS-v2 venv + model + uv cache). Voz `pt_BR-faber-medium.onnx` (63MB) mantida em `~/.cache/agent-tts/voices/` para uso em v0.6+.

---

## v0.3 — SQLite WAL queue + queue/skip/clear · 2026-06-03

**Entregue**:

- Fila migrada de in-memory `ArrayList` para **SQLite WAL** em `~/.cache/agent-tts/queue.db` — sobrevive crash do daemon + reboot
- Schema `items(id, text, voice, rate, state, enqueued_at, started_at, finished_at)` + index parcial em `state IN ('pending','playing')`
- Crash recovery no boot: `UPDATE state='pending' WHERE state='playing'` re-promove órfãos do crash anterior
- 3 novos subcomandos: `agent-tts queue` (lista pending+playing), `agent-tts skip` (mata `say` atual via SIGTERM), `agent-tts clear` (marca pendentes como skipped)
- Protocolo IPC estendido: `ENQUEUE` (igual v0.2) + `QUEUE`, `SKIP`, `CLEAR` + resposta `ITEM\t...\n` + `END\n` pra QUEUE
- Worker reescrito: drena via SQLite, registra PID do child com queue antes do `wait()`, SKIP envia SIGTERM no PID guardado
- `@cImport(sqlite3.h)` + `linkSystemLibrary("sqlite3", .{})` — usa libsqlite3 do SDK macOS, sem submodule

**Medições** (Mac Air M4, daemon quente, baseline em `_qa/v0.3-baseline.md`):

| Métrica | Valor | Alvo v0.3 |
|---------|-------|-----------|
| Round-trip ACK enqueue (mediana, 7 calls) | 0.1ms | informativo |
| Round-trip ACK queue (mediana, 5 calls) | 0.1ms | informativo |
| Round-trip ACK skip | <10ms (limite de medição) | informativo |
| Binary size (ReleaseFast) | 476KB | <1MB |
| Persistência (kill -9 mid-play) | ✅ 3/3 items drenam pós-restart | "fila sobrevive crash" |

Critério do roadmap "fila sobrevive crash do daemon" cumprido: matar daemon + `say` durante a fala deixa item em `playing` na DB; restart re-promove órfão pra `pending` e o worker dreina sequencialmente.

**Gaps que viram v0.4**:

- Daemon ainda foreground — `launchd` plist + `agent-tts daemon install` ficam em v0.4
- Sem auto-start (fork+exec) quando client encontra socket morto — v0.4
- TTFA real (audio sample detection) ainda não medido — gap herdado de v0.2, segue pra v0.4 com `dtruss`

**Não fechou nesta versão** (movido):

- Preprocessor de pausas + números → v0.5
- libpiper FFI → v0.6
- AVSpeechSynthesizer embed (escape de cold-start do `say`) → reavaliação só se v0.4 medir TTFA >300ms

---

## v0.2 — daemon + socket + fila in-memory · 2026-06-03

**Entregue**:

- Daemon foreground (`agent-tts daemon`) com socket UNIX em `~/.cache/agent-tts/sock`
- Fila in-memory thread-safe (`std.Io.Mutex` + `std.Io.Condition` + `std.ArrayList`)
- Worker thread única dreina a fila chamando `say` — playback serializado, nunca paralelo
- Pre-warm da voz Luciana no boot do daemon (`say -v Luciana " "`)
- Cliente faz round-trip via socket: ENQUEUE → ACK em sub-100µs
- Protocolo de linha simples: `ENQUEUE\t<voice>\t<rate>\t<text>\n` → `OK\t<id>\n` ou `ERR\t<msg>\n`
- Binary 455KB arm64 Mach-O (era 415KB em v0.1, +40KB pelo thread + socket + queue)

**Medições** (Mac Air M4, daemon quente, baseline em `_qa/v0.2-baseline.md`):

| Métrica | Valor | Alvo v0.2 |
|---------|-------|-----------|
| Round-trip ACK (mediana, 7 calls) | 0.0ms | < 400ms |
| Pre-warm cold (boot único) | 340.3ms | informativo |

Alvo do roadmap era TTFA quente <400ms. Round-trip ACK <100µs sai 4000x abaixo do teto — daemon responde muito antes do áudio começar. TTFA real (primeiro sample audível) ainda precisa dtruss + captura de áudio, fica para v0.3.

**Gaps que viram v0.3**:

- Fila não sobrevive restart do daemon → SQLite WAL
- Sem comandos `agent-tts queue` / `skip` / `clear`
- TTFA real (audio sample) ainda não medido

**Não fechou nesta versão** (movido):

- Auto-start (fork+exec ou launchd) → v0.4
- Preprocessor de pausas + números → v0.5

---

## v0.1 — `say` direto sem daemon · 2026-06-03

**Entregue**:

- CLI Zig 0.16 single-binary, 415KB arm64 ReleaseFast
- `agent-tts "texto"` chama `say -v Luciana -r 330` direto
- Flags `--voice NAME --rate WPM -h --help -V --version`
- Default voice **Luciana**, default rate **330wpm** (sweet spot decidido por ouvido — 180 lento, 430 seco)

**Medições** (baseline em `_qa/v0.1-baseline.md`):

| Métrica | Valor |
|---------|-------|
| Spawn latency (mediana, 5 runs) | 0.8ms |
| Rate 180 → 600 sweep | redução linear até 540, plateau acima |

Spawn = tempo até `std.process.spawn` retornar. Não é TTFA real.

**Vozes testadas — só Luciana sobreviveu**:

Outras vozes Pt-BR instaladas (Eddy, Flo, Rocko, Reed, Sandy, Grandma, Grandpa, Shelley) — reprovadas por qualidade. Luciana Premium não instalada na máquina de teste; quando instalada, vira default.
