#!/bin/sh
set -e
umask 077

: "${BRIDGE_TOKEN:?Defina BRIDGE_TOKEN com pelo menos 32 caracteres aleatórios}"
if [ "${#BRIDGE_TOKEN}" -lt 32 ]; then
  echo "BRIDGE_TOKEN deve ter pelo menos 32 caracteres aleatórios" >&2
  exit 1
fi

BRIDGE_PORT="${BRIDGE_PORT:-8080}"
BRIDGE_DB_PATH="${BRIDGE_DB_PATH:-/data/bridge/whatsapp.db}"
GLEAM_PORT="${PORT:-4000}"

export WHATSMEOW_URL="http://127.0.0.1:${BRIDGE_PORT}"
export GLEAM_URL="http://127.0.0.1:${GLEAM_PORT}/webhook"
export BRIDGE_HOST="${BRIDGE_HOST:-127.0.0.1}"
export MEDIA_TEMP_DIR="${MEDIA_TEMP_DIR:-/tmp/amelie-media}"

mkdir -p "$(dirname "$BRIDGE_DB_PATH")"

echo "[amelie] Iniciando supervisor do bridge (porta ${BRIDGE_PORT})..."
(
  while true; do
    if /usr/local/bin/amelie-bridge; then
      bridge_exit=0
    else
      bridge_exit=$?
    fi
    echo "[amelie] Bridge terminou com código ${bridge_exit}. Reiniciando em 2s..."
    sleep 2
  done
) &

echo "[amelie] Iniciando app (porta ${GLEAM_PORT})..."
exec erl \
  -pa /app/build/erlang-shipment/*/ebin \
  -eval "'amelie_gleam@@main':run(amelie_gleam)." \
  -noshell
