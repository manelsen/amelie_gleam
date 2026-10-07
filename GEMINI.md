# Amélie WhatsApp Bot (Gleam/BEAM)

Amélie is a WhatsApp bot implemented in Gleam, targeting the Erlang/BEAM runtime. It uses a hexagonal architecture to maintain a pure functional core while interacting with external services like WhatsApp (via a Go bridge) and various AI providers (Google Gemini, OpenRouter).

## Project Overview

- **Purpose:** Provide an intelligent WhatsApp assistant capable of processing text, images, audio, video, and documents.
- **Architecture:** Ports & Adapters (Hexagonal Architecture).
- **Main Technologies:**
  - **Language:** [Gleam](https://gleam.run/) (Erlang target)
  - **Runtime:** Erlang/OTP (BEAM)
  - **HTTP Server:** [Mist](https://github.com/lpil/mist)
  - **Database:** SQLite (via [sqlight](https://github.com/lpil/sqlight))
  - **AI Providers:** Google Gemini (primary), OpenRouter (fallback/alternative)
  - **WhatsApp Bridge:** [whatsmeow](https://github.com/tulir/whatsmeow) (Go)

## Directory Structure

```text
src/
├── adaptadores/      # Concrete implementations of ports (HTTP clients, SQLite)
├── core/             # Pure business logic (Processor, Command Dispatcher, Validations)
├── dominio/          # Pure domain types (Acao, Config, Mensagem, Erro)
├── portas/           # Port interfaces (Abstract types as records of functions)
├── shell/            # Effectful orchestration layer (Executes Acao values, Actors)
└── amelie_gleam.gleam # Entry point: Wires everything and starts the HTTP server
whatsmeow-bridge/     # Go bridge for connecting to WhatsApp
config/               # Configuration files (providers.yaml)
db/                   # SQLite database files
test/                 # Test suite (mirrors src/ structure)
```

## Building and Running

### Commands

- **Build:** `gleam build`
- **Test:** `gleam test`
- **Run (Local):** 
  ```bash
  GEMINI_API_KEY=your_key WHATSMEOW_URL=http://localhost:8080 DB_PATH=./db/amelie.sqlite PORT=4000 gleam run
  ```
- **Deployment (Docker):** `docker-compose up -d --build` (starts both the Gleam app and the Go bridge)

### Environment Variables

| Variable | Default | Description |
|---|---|---|
| `GEMINI_API_KEY` | `""` | Google Gemini API key |
| `OPENROUTER_API_KEY` | `""` | OpenRouter API key |
| `WHATSMEOW_URL` | `http://localhost:8080` | URL of the whatsmeow-bridge |
| `DB_PATH` | `./db/amelie.sqlite` | Path to the SQLite database |
| `PORT` | `4000` | HTTP server port |
| `OFFLINE_RETRY_INTERVAL_MS`| `30000` | Interval for retrying offline messages |

## Development Conventions

### Hexagonal Architecture Principles
- **Pure Core:** Logic in `core/` and `dominio/` must be pure. No IO, no side effects.
- **Port-Based Dependency:** The shell and core interact with external systems only through the interfaces defined in `portas/`.
- **Acao Pattern:** The core never performs actions; it returns `List(Acao)` which describes what the shell should do.

### Workflow & Reliability
- **Non-blocking Webhooks:** The `/webhook` endpoint returns `202 Accepted` immediately. Message processing happens in an isolated process via `spawn_fn`.
- **Deduplication:** Messages are tracked in the `transacoes` table to avoid processing the same `message_id` multiple times (especially during WhatsApp history sync).
- **Message Age Filter:** Messages older than 48 hours are ignored to prevent processing old history on startup.
- **Media Limits:** `mist.read_body` is set to 20MB to accommodate large media files (Audio/Images).
- **Async Media:** Large media processing (transcription, description) is handled by OTP actors in `shell/fila_midia.gleam`.

### Coding Style
- **Gleam Patterns:** Prefer `use` for monadic operations (Result, Option, Decoder).
- **JSON Decoding:** Use `gleam_json` decoders. Note that `sqlight` decoders use positional indexing (`decode.at([0], ...)`).
- **FFI:** Erlang FFI is used for system-level calls (OS environment, file reading) in `src/amelie_gleam_ffi.erl`.

## Key Logic Paths

1. **Incoming Message:** `amelie_gleam.gleam` receives POST -> Decodes to `Mensagem` -> Calls `handler_mensagem.handle`.
2. **Processing:** `handler_mensagem` fetches `Config` and `Historico` -> Calls `core/processador.processar` (Pure) -> Receives `List(Acao)`.
3. **Execution:** `handler_mensagem` iterates over `Acao` list and executes each via relevant ports (IA, Whatsapp, SQLite).
