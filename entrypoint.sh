#!/bin/sh
set -e

BRIDGE_PORT="${BRIDGE_PORT:-8080}"
BRIDGE_DB_PATH="${BRIDGE_DB_PATH:-/data/bridge/whatsapp.db}"
GLEAM_PORT="${PORT:-4000}"

export WHATSMEOW_URL="http://localhost:${BRIDGE_PORT}"
export GLEAM_URL="http://localhost:${GLEAM_PORT}/webhook"

mkdir -p "$(dirname "$BRIDGE_DB_PATH")"

echo "[amelie] Iniciando bridge (porta ${BRIDGE_PORT})..."
/usr/local/bin/amelie-bridge &
BRIDGE_PID=$!

echo "[amelie] Iniciando app (porta ${GLEAM_PORT})..."
exec erl \
  -pa /app/build/erlang-shipment/*/ebin \
  -eval "'amelie_gleam@@main':run(amelie_gleam)." \
  -noshell
