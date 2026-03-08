# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Amélie is a WhatsApp bot written in Gleam (targeting the BEAM/Erlang runtime). It receives webhook events from a `whatsmeow` Go bridge, processes them through a pure functional core, and responds via Google Gemini AI.

## Commands

```bash
# Build
gleam build

# Run tests
gleam test

# Run the bot (requires env vars)
GEMINI_API_KEY=... WHATSMEOW_URL=http://localhost:8080 DB_PATH=./db/amelie.sqlite PORT=4000 gleam run
```

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `GEMINI_API_KEY` | `""` | Google Gemini API key |
| `WHATSMEOW_URL` | `http://localhost:8080` | whatsmeow HTTP bridge URL |
| `DB_PATH` | `./db/amelie.sqlite` | SQLite database path |
| `PORT` | `4000` | HTTP server port (Mist) |

## Architecture

The codebase follows a strict **ports & adapters (hexagonal)** pattern with a pure functional core:

```
dominio/       — Pure domain types. No imports from external packages.
core/          — Pure business logic. No side effects. Receives data, returns Acao.
portas/        — Port interfaces (abstract types as records of functions).
adaptadores/   — Concrete implementations of ports (HTTP clients, SQLite).
shell/         — Effectful orchestration layer. Executes the Acao values from core.
amelie_gleam.gleam — Entry point: wires adapters → ports → Mist HTTP server.
```

### Data flow

1. `POST /webhook` → `amelie_gleam.gleam` decodes JSON into `Mensagem`
2. `shell/handler_mensagem.handle` fetches `Config` + `Historico` from ports, calls `core/processador.processar`
3. `core/processador` (pure) returns `List(Acao)` — never calls IO
4. Shell executes each `Acao`: calls IA port, WhatsApp port, saves history
5. Media (`Imagem`, `Audio`, `Video`, `Documento`) is dispatched to `shell/fila_midia` — an OTP actor for async processing

### Key types

- `dominio/mensagem.Mensagem` — inbound message (chat_id, remetente, corpo: `Conteudo`, timestamp, em_grupo, menciona_bot)
- `dominio/acao.Acao` — `EnviarTexto | EnviarReacao | EnfileirarMidia | NaoResponder`
- `dominio/config.Config` — per-chat configuration (model, history limit, media toggles, system prompt, language)
- `shell/handler_mensagem.Portas` — record bundling all live port implementations

### Ports (abstract interfaces as record-of-functions)

- `portas/ia_porta.IAPorta` — Gemini AI (text, image, audio, video, document, upload, poll, delete)
- `portas/whatsapp_porta.WhatsappPorta` — send messages via whatsmeow bridge
- `portas/config_porta.ConfigPorta` — per-chat config CRUD
- `portas/historico_porta.HistoricoPorta` — conversation history CRUD

### Adapters

- `adaptadores/gemini_http` → implements `IAPorta` (Google Gemini REST API)
- `adaptadores/whatsmeow_http` → implements `WhatsappPorta`
- `adaptadores/config_sqlite` → implements `ConfigPorta`
- `adaptadores/historico_sqlite` → implements `HistoricoPorta`

### Commands

Text messages starting with `.` are parsed as bot commands (e.g. `.ajuda`, `.reset`, `.audio on`). Command dispatch lives in `core/comando/dispatcher.gleam` — pure, returns `List(Acao)`.

### FFI

`src/amelie_gleam_ffi.erl` provides Erlang FFI for `get_env/1` (reads OS env vars) and `read_file/1` (reads binary files for video upload).

## Gleam-specific notes

- Uses `gleam_otp` 1.x builder pattern for actors: `actor.new(state) |> actor.on_message(...) |> actor.start()`
- Uses `gleam_json` 3.x: `json.parse(str, decoder)` (not `json.decode`)
- Decoder pattern: `decode.at([...], decode.string)` for nested JSON paths
- SQLite via `sqlight`: decoders use positional index `decode.at([0], ...)` for column access
