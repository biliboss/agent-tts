---
title: Changelog
description: Marcos entregues e medições reais por versão.
---

## TL;DR

Por marco: o que entregou, como medimos, o que ficou para o próximo. KPI único é TTFA. Sem número publicado, marco não fechou.

---

## v0.6 — libpiper FFI baseline · 2026-06-03

**Entregue**:

- Vendor build de `libpiper.dylib` a partir de [OHF-Voice/piper1-gpl](https://github.com/OHF-Voice/piper1-gpl) tag v1.4.2 (espeak-ng estático + ONNX Runtime 1.22.0 baixados pelo CMake do projeto). Receita reproduzível em `vendor/README.md`, fonte gitignored
- `src/piper.zig` — `PiperEngine` struct via `@cImport piper.h`: `init(voice_path, espeak_data_path)` carrega o modelo, `synthToWav(io, text, out_path)` sintetiza e escreve PCM s16le mono WAV
- `build.zig` — opção `-Dwith-piper=true` linka `libpiper` + `c++` com `rpath` pra `vendor/.../dist/lib/`. Default OFF mantém binário fininho pra quem usa só `say`
- Subcomando experimental `agent-tts piper-test "<text>" <out.wav>` faz bypass do daemon e mede init + synth cold
- Daemon boot opcional: `AGENT_TTS_PIPER=1 agent-tts daemon` carrega `PiperEngine` ao lado do pre-warm Luciana — engine fica resident mas v0.6 NÃO roteia playback ainda (v0.7 faz isso com zaudio)
- Voz `pt_BR-faber-medium.onnx` (63MB) baixada em `~/.cache/agent-tts/voices/`

**Medições** (Mac Air M4, ReleaseFast, baseline em `_qa/v0.6-baseline.md`):

| Métrica | Valor | Alvo v0.6 |
|---------|-------|-----------|
| Piper init cold (filesystem cache miss) | 646.7ms | informativo |
| Piper init warm (FS cached) | ~460ms | informativo |
| Synth + WAV — utterance curta (3-5 palavras) | 60-110ms | — |
| Synth + WAV — parágrafo 268 chars | 731ms | — |
| Total curto (init+synth) | ~535ms | <1s ✅ |
| Total longo (init+synth) | ~1217ms | <1s ❌ (200ms over) |
| Daemon piper engine load | 397ms | <500ms ✅ |
| Binary size sem piper | 455 288 B | baseline |
| Binary size com piper | 457 336 B | +2 KB |

Curto bate o alvo; longo passa em 200ms na cold. v0.7 elimina o init cost ao
reusar engine resident — synth puro de parágrafo é 731ms, ainda dentro de 1s
warm.

**Gotcha durante build**: espeak-ng define `N_PATH_HOME=160` e o path absoluto
da worktree do vault (>160 chars) silenciosamente trunca nomes de arquivo
durante a compilação dos fonemas. Workaround: buildar em `/tmp/piper-build` e
linkar `vendor/.../libpiper/build` como symlink. Documentado em `vendor/README.md`.

**License**: GPL-3.0 herda do libpiper + espeak-ng quando agent-tts for
distribuído com a dylib. v0.6 só roda local — decisão de licença pública fica
pra v1.0 (brew tap).

**Gaps que viram v0.7**:

- Engine load duplica (daemon boot + piper-test). v0.7 expõe a engine resident via socket
- WAV em disco + afplay → substituir por zaudio streaming PCM (TTFA real cai)
- TTFA real (primeiro sample audível) ainda não medido na trilha Piper
- Flag `--engine say|piper` no client
- Code-switch EN ("GitHub Actions") continua errado — Faber é mono Pt (v1.1+ multilingual ONNX)

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
