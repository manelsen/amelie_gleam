# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Amélie is a WhatsApp bot written in Gleam (targeting the BEAM/Erlang runtime). It receives webhook events from a `whatsmeow` Go bridge (`whatsmeow-bridge/`), processes them through a pure functional core, and responds via multimodal AI providers (Google Gemini primary, OpenRouter fallback/alternative).

**Structure:**
- `src/` — Gleam code (hexagonal architecture: domain, core, ports, adapters, shell)
- `whatsmeow-bridge/` — Go bridge for WhatsApp connection via `whatsmeow`
- `config/` — External provider and model settings (`providers.yaml`)
- `docker-compose.yml` — Containerized unified deployment
- `DEPLOYMENT.md` — Full deployment and operations guide
- `ROADMAP.md` — Technical roadmap, status, and priorities

## Commands

### Development
```bash
# Build Gleam application
gleam build

# Run full Gleam test suite
gleam test

# Check formatting
gleam format --check src test

# Format code
gleam format

# Run Go bridge tests
cd whatsmeow-bridge && go test -count=1 ./...

# Build Go bridge binary
cd whatsmeow-bridge && go build .

# Run the Gleam app only (requires bridge running separately)
BRIDGE_TOKEN=... GEMINI_API_KEY=... WHATSMEOW_URL=http://localhost:8080 DB_PATH=./db/amelie.sqlite PORT=4000 gleam run
```

### Production (Docker Compose)
```bash
# Build and start services (bridge + Gleam app)
docker compose up -d --build

# View logs
docker compose logs -f

# Stop
docker compose down
```

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `GEMINI_API_KEY` | `""` | Google Gemini API key (primary) |
| `OPENROUTER_API_KEY` | `""` | OpenRouter API key (fallback/alternative) |
| `TELEGRAM_BOT_TOKEN` | `""` | Telegram Bot API token (enables Telegram channel) |
| `TELEGRAM_SECRET_TOKEN` | `""` | Required for incoming webhook; empty disables the endpoint (polling still works) |
| `TELEGRAM_ADMIN_CHAT_ID` | `""` | Admin Telegram Chat ID for RBAC `/status`, `/reset_whatsapp`, `/parear` |
| `MOBILE_NUMBER` | `""` | Bot phone number for WhatsApp Pairing Code (optional) |
| `WHATSMEOW_URL` | `http://localhost:8080` | whatsmeow HTTP bridge URL |
| `DB_PATH` | `/data/amelie.sqlite` | SQLite database path |
| `BRIDGE_DB_PATH` | `/data/bridge/whatsapp.db` | whatsmeow device/session SQLite path |
| `PORT` | `4000` | HTTP server port (Mist) |
| `BRIDGE_PORT` | `8080` | Internal bridge HTTP port |
| `OFFLINE_RETRY_INTERVAL_MS`| `30000` | Interval for retrying offline messages |
| `BRIDGE_TOKEN` | `""` | Required shared random secret, at least 32 characters |
| `BRIDGE_HOST` | `127.0.0.1` | Private bridge listener |
| `MEDIA_TEMP_DIR` | `/tmp/amelie-media` | Private 0700 spool shared by Gleam and bridge |

`WHATSMEOW_URL` and `GLEAM_URL` are configured automatically by `entrypoint.sh` inside Docker.

## Architecture

The codebase follows a strict **ports & adapters (hexagonal)** pattern with a pure functional core:

```text
dominio/       — Pure domain types. No side effects, no external dependencies.
core/          — Pure business logic. Deterministic. Receives data, returns List(Acao).
portas/        — Port interfaces (abstract types as records of functions).
adaptadores/   — Concrete implementations of ports (HTTP clients, SQLite).
shell/         — Effectful orchestration layer. Executes Acao values and OTP actors.
amelie_gleam.gleam — Entry point: wires adapters → ports → Mist HTTP server.
```

### Data Flow

1. `POST /webhook` (WhatsApp) or `POST /webhook/telegram` (Telegram) → `amelie_gleam.gleam` decodes payload into `Webhook(msg, arquivo)`.
2. Large incoming media from WhatsApp is offloaded to `MEDIA_TEMP_DIR/amelie_midia_*` by the bridge. `amelie_gleam.gleam` reads the file via Erlang FFI into `BitArray`, then deletes the temporary file. Telegram media is fetched asynchronously via `getFile`.
3. `shell/handler_mensagem.handle` fetches `Config` + `Historico` from ports, calls `core/processador.processar`.
4. `core/processador` (pure) returns `List(Acao)` — never performs IO.
5. Shell executes each `Acao`:
   - `GerarEEnviar`: invokes AI provider via `ia_dispatcher` and sends reply via `entrega_auditada` (routed by `roteador_mensageiro` according to `chat_id`).
   - `EnviarResposta`: directly sends text (commands, help, errors) without invoking AI.
   - `EnfileirarMidia`: dispatches to `shell/fila_midia` — dedicated OTP actors for `imagem`, `audio`, `video`, `documento`, and `sticker`.
   - `BuscarUrlEResponder`: fetches public web content through the bridge’s authenticated `/fetch` endpoint, with DNS pinning, redirect checks, time and size limits.
   - `BaixarVideoUrlEDescrever`: returns an explicit disabled-feature message; downloading external video links is disabled for SSRF protection.

### Key Types

- `dominio/mensagem.Mensagem` — chat_id, remetente, corpo (`Conteudo`), timestamp, em_grupo, menciona_bot, legenda.
- `dominio/mensagem.Conteudo` — `Texto | Imagem | Audio | Video | Documento | Sticker | MidiaIndisponivel | Comando`.
- `dominio/acao.Acao` — `GerarEEnviar | BuscarUrlEResponder | BaixarVideoUrlEDescrever | EnviarResposta | EnviarReacao | EnfileirarMidia | SalvarConfig | LimparHistorico | AlterarModelo | SnapshotHistorico | NaoResponder`.
- `dominio/config.Config` — per-chat configuration (provedor, modelo default `gemini-3.8-flash`, historico_max, media toggles, modo_descricao).
- `shell/handler_mensagem.Portas` — record bundling all active port implementations.

### Ports (Abstract interfaces as record-of-functions)

- `portas/mensageiro_porta.MensageiroPorta` — send messages and reactions (WhatsApp bridge, Telegram).
- `portas/ia_porta.IAPorta` — Gemini / OpenRouter AI operations (text, image, audio, video, document, file upload/poll/delete).
- `portas/config_porta.ConfigPorta` — per-chat config persistence.
- `portas/historico_porta.HistoricoPorta` — conversation history persistence and snapshots.
- `portas/transacao_porta.TransacaoPorta` — delivery tracking and offline queue persistence.
- `portas/usuario_porta.UsuarioPorta` — user registration and listing.
- `portas/grupo_porta.GrupoPorta` — group registration and listing.
- `portas/prompt_porta.PromptPorta` — custom system prompts persistence.

### Adapters

- `adaptadores/whatsmeow_http` → implements `MensageiroPorta` for WhatsApp (calls Go bridge, parses structured `APIError` and network errors).
- `adaptadores/telegram_http` → implements `MensageiroPorta` for Telegram (sends text, chat actions, reactions, downloads media).
- `adaptadores/roteador_mensageiro` → routes calls to `whatsmeow_http` or `telegram_http` based on `chat_id` prefix (`tg:` vs WhatsApp JID).
- `adaptadores/gemini_http` → implements `IAPorta` (Google Gemini REST & File API).
- `adaptadores/openrouter_http` → implements `IAPorta` (OpenRouter API).
- `adaptadores/config_sqlite` → implements `ConfigPorta` (includes auto-migration to `gemini-3.8-flash`).
- `adaptadores/historico_sqlite` → implements `HistoricoPorta`.
- `adaptadores/transacao_sqlite` → implements `TransacaoPorta`.
- `adaptadores/usuario_sqlite`, `grupo_sqlite`, `prompt_sqlite` → SQLite storage.

### Commands

Messages starting with `.` or `/` (or without prefix where supported) are parsed as bot commands:
- `.ajuda` / `/ajuda` — help text.
- `.reset` / `/reset` — reset chat configuration and conversation history.
- `.audio`, `.imagem`, `.video`, `.doc` — alternar processamento de mídia (toggle liga/desliga).
- `.legenda` — toggle video transcription vs description.
- `.longo` / `.curto` — toggle detailed vs concise image descriptions.
- `.cego` — accessibility mode for visually impaired users.
- `.modelo [provedor/modelo]` — display or switch active provider and model (e.g. `.modelo gemini/gemini-2.5-pro`).

#### Admin Commands (Telegram only, restricted to `TELEGRAM_ADMIN_CHAT_ID`)
- `/status` — real-time status of WhatsApp and Telegram channels, BEAM memory/process metrics, and message counters.
- `/reset_whatsapp` — unlinks WhatsApp session, resets session database, recreates client device, and triggers pairing code generation.
- `/parear <phone>` — generates a fresh WhatsApp pairing code for the specified phone number and delivers it directly to the admin in Telegram.

### FFI

`src/amelie_gleam_ffi.erl` provides Erlang FFI for:
- `get_env/1` — OS environment variables.
- `spawn_fn/1` — asynchronous OTP process spawning.
- `read_file/1` and `delete_file/1` — temporary media file reading and cleanup.
- `total_memory/0`, `processes_memory/0`, `process_count/0` — BEAM runtime metrics.

## Regras de trabalho

- Quando o usuário reportar que algo não funciona, rastrear o caminho completo do dado em runtime (quem chama → quem passa o argumento → quem envia ao serviço externo) antes de sugerir causa externa (deploy, cache, restart). Código que existe mas não é alcançado é código morto.
- `mist.read_body` em `amelie_gleam.gleam` deve ser no mínimo `20 * 1024 * 1024` para suportar payloads de mídia de entrada.
- Sempre rodar `gleam test` e `cd whatsmeow-bridge && go test -count=1 ./...` antes de concluir modificações.
- Seguir o padrão de commits convencionais em português (`feat`, `fix`, `chore`, `refactor`, `docs`).
