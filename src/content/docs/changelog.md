---
title: Changelog
description: Marcos entregues e medições reais por versão.
---

## TL;DR

Por marco: o que entregou, como medimos, o que ficou para o próximo. KPI único é TTFA. Sem número publicado, marco não fechou.

---

## v0.5 — preprocessor Pt-BR (cadência humana) · 2026-06-03

**Entregue**:

- `src/preproc.zig`: 3 transforms encadeados, single-pass por estágio, alocação via arena por mensagem
  - Abreviações whole-word: `Sr. Sra. Dr. Dra. cf. etc. vs. nº Av. R$`
  - Cardinais Pt-BR 0..9999 (state machine sobre dígitos; skipa se grudado em letra ou `%`; suporte a negativos `-5` → "menos cinco" e zero)
  - Pausas `[[slnc N]]` para `,` (150ms), `.` `!` `?` (400ms), `\n` (600ms); pontuação consecutiva colapsa pra maior do grupo
- Hook em `tts.zig`: `play()` roda o preproc antes do argv do `say`. Falha do preproc é não-fatal — log + fallback pro texto raw (best-effort, mensagem nunca cai)
- Binary 459KB arm64 Mach-O (era 455KB em v0.2, +4KB pelo módulo)
- `VERSION = "0.5.0"`, linha sobre "preprocessor active" no `--help`
- 26 testes novos cobrindo cada transform + edge cases (empty, only-punct, mid-word não-match, out-of-range, mixed). `zig build test` = 27/27

**Medições** (Mac Air M4, ReleaseFast, 1000 iter por caso, arena fresca por iter; baseline em `_qa/v0.5-baseline.md`):

| Caso | input bytes | mediana | média |
|------|-------------:|--------:|------:|
| short greeting (`Olá, mundo.`) | 12 | 2.0 µs | 1.5 µs |
| `Sr. Silva tem 25 anos, certo?` | 29 | 4.0 µs | 3.4 µs |
| `Av. Paulista, nº 1578.` | 23 | 3.0 µs | 3.2 µs |
| `Estamos em 2026 e devemos R$ 1234…` | 47 | 4.0 µs | 3.5 µs |
| long mixed paragraph | 151 | 5.0 µs | 4.4 µs |

Orçamento era < 1ms por mensagem; entregamos 200× abaixo. Zero risco de regressão TTFA.

**Decisões honestas**:

- `Sr.` consome o ponto (vira "Senhor", sem pausa subsequente). Tratado como abreviação, não terminador
- `R$` é substituição cega, não reordena: `R$ 500` → "reais quinhentos" (não "quinhentos reais"). Suficiente até alguém reclamar
- Connector "e" em milhares segue regra Pt-BR: `1500` = "mil e quinhentos", `1578` = "mil quinhentos e setenta e oito"
- Cap em 9999 — números maiores ficam crus (`say` lê dígito-a-dígito)
- Frações, horários (`14h30`), decimais ainda literais. YAGNI até demanda real

**Não fechou nesta versão** (movido):

- v0.3 (SQLite WAL + queue/skip/clear)
- v0.4 (launchd auto-start)

---

## Benchmark interlúdio · 2026-06-03

Antes de codar v0.3, gastei uma sessão benchmarkando motores alternativos pra resolver code-switching Pt+En. Conclusões em [Motor TTS](/motor/). Resumo:

- Piper Faber via Python — mono Pt, rejeitado
- XTTS-v2 multilingual via Python — 27s/call CLI, sidecar Python rejeitado pela restrição "only Zig"
- Decisão: **libpiper FFI** (de OHF-Voice/piper1-gpl) entra como v0.6-v0.7, traz voz Faber + ONNX runtime nativo via `@cImport`, struct `PiperEngine` owner, zaudio pra streaming PCM
- Code-switching EN fica não-resolvido até v1.1+ (ONNX multilingual maduro)

Limpeza: 3.2GB liberados (XTTS-v2 venv + model + uv cache). Voz `pt_BR-faber-medium.onnx` (63MB) mantida em `~/.cache/agent-tts/voices/` para uso em v0.6+.

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
