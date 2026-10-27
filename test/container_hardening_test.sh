#!/bin/sh
# Verifica o endurecimento do container em execução (achado A2 do relatório
# de segurança). Rode depois de `docker compose up -d --build`:
#
#   sh test/container_hardening_test.sh
#
# Falha se algum processo do app rodar como root, se o sistema de arquivos
# aceitar escrita fora de /data e /tmp, ou se o volume não for do usuário amelie.
set -eu

servico="${1:-amelie}"
falhas=0

falhar() {
  echo "FALHA: $1"
  falhas=$((falhas + 1))
}

exec_c() {
  docker compose exec -T "$servico" sh -c "$1"
}

# 1. Nenhum processo do app como root (o entrypoint já trocou de usuário).
processos_root=$(exec_c 'ps -o user= -o comm=' | awk '$1 == "root" && $2 != "ps" && $2 != "sh"')
if [ -n "$processos_root" ]; then
  falhar "processos rodando como root:
$processos_root"
fi

# 2. beam e bridge rodam como amelie.
for alvo in beam.smp amelie-bridge; do
  dono=$(exec_c "ps -o user= -o comm=" | awk -v c="$alvo" '$2 == c {print $1; exit}')
  if [ "$dono" != "amelie" ]; then
    falhar "$alvo roda como '${dono:-ausente}', esperado 'amelie'"
  fi
done

# 3. Sistema de arquivos só leitura fora de /data e /tmp.
if exec_c 'touch /app/teste_escrita 2>/dev/null'; then
  falhar "/app aceitou escrita (read_only não aplicado)"
  exec_c 'rm -f /app/teste_escrita' || true
fi

# 4. Volume pertence a amelie.
dono_data=$(exec_c 'stat -c %U /data')
if [ "$dono_data" != "amelie" ]; then
  falhar "/data pertence a '$dono_data', esperado 'amelie'"
fi

if [ "$falhas" -gt 0 ]; then
  echo "$falhas verificação(ões) falharam"
  exit 1
fi
echo "OK: container sem root, só leitura fora de /data e /tmp"
