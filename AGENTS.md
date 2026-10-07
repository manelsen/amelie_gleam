# Repository Guidelines

## Project Structure & Module Organization

This is a Gleam/BEAM WhatsApp bot with a small Go bridge. Main Gleam code lives in `src/`: `dominio/` holds domain types, `core/` contains pure business logic, `portas/` defines interfaces, `adaptadores/` implements external services and SQLite persistence, and `shell/` coordinates runtime effects such as queues, metrics, and handlers. Tests mirror this layout under `test/`, with reusable fixtures in `test/helpers/`. Runtime configuration is in `config/providers.yaml`, `.env.example`, `Dockerfile`, `docker-compose.yml`, and `entrypoint.sh`. The WhatsApp bridge lives in `whatsmeow-bridge/`.

## Build, Test, and Development Commands

- `gleam deps download`: fetch Gleam dependencies from `gleam.toml`.
- `gleam test`: run the Gleam test suite with Gleeunit.
- `gleam format`: format Gleam source and tests before committing.
- `gleam run`: run the Gleam app locally; configure `.env` and ensure a bridge is available.
- `cd whatsmeow-bridge && go test ./...`: run bridge unit tests.
- `cd whatsmeow-bridge && go build .`: build the bridge binary.
- `docker compose up --build`: build and run the full app plus bridge wiring locally.

## Coding Style & Naming Conventions

Follow standard Gleam formatting: two-space indentation, pipeline-friendly transformations, and explicit result handling. Keep core modules pure where possible; external effects belong in `adaptadores/` or `shell/`. Existing code uses Portuguese module and function names, for example `processar_texto`, `mensagem`, and `config_padrao`; keep new names consistent with nearby code. Go bridge code should use `gofmt` and idiomatic table-driven tests.

## Testing Guidelines

Add Gleam tests in `test/**` using `*_test.gleam` files and public functions ending in `_test`. Prefer fixtures from `test/helpers/fixtures.gleam` and fakes from `test/helpers/portas_fake.gleam` over hand-built setup. Cover pure `core/` behavior directly, then add shell or adapter tests only when the change affects runtime coordination. For bridge changes, add or update Go tests in `whatsmeow-bridge/main_test.go`.

## Commit & Pull Request Guidelines

Recent history uses Conventional Commits in Portuguese, such as `fix(whatsapp): renovar midia em erro DNS` and `feat(video): descrever links com yt-dlp`. Use `feat`, `fix`, `chore`, or similar types with a narrow scope. PRs should explain behavior changes, mention config or migration impacts, link related issues, and include test results. Include screenshots or logs only for user-visible runtime behavior.

## Security & Configuration Tips

Do not commit `.env`, `db/`, cookies, API keys, or generated media. Start from `.env.example`, keep provider settings in `config/providers.yaml`, and document any new required environment variable in both places when applicable.
