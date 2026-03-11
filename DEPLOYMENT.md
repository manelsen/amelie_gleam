# Deployment - Amélie Gleam

## Estrutura

```
amelie_gleam/
├── src/                    # Código Gleam
├── whatsmeow-bridge/       # Bridge Go (incluído no build)
├── db/                     # Volume de dados (SQLite + sessão WhatsApp)
├── Dockerfile              # Build unificado (bridge + app)
├── entrypoint.sh           # Sobe bridge em background, Gleam em foreground
├── docker-compose.yml      # Um único serviço
├── .env.example            # Template de configuração
└── .env                    # Suas chaves (NÃO commitar!)
```

## Deploy

### Pré-requisitos
- Docker e Docker Compose

### Passo a Passo

```bash
cp .env.example .env
# edite .env com suas chaves

docker-compose up -d --build
```

### Conectar o WhatsApp

O bridge exibe o QR Code ou usa Pairing Code nos logs:

```bash
docker-compose logs -f
```

Escaneie com WhatsApp → Aparelhos Conectados, ou aguarde o Pairing Code
se `MOBILE_NUMBER` estiver configurado.

### Comandos Úteis

```bash
docker-compose logs -f          # logs em tempo real
docker-compose restart          # reiniciar
docker-compose down             # parar
docker-compose up -d --build    # rebuild + reiniciar
docker-compose exec amelie sh   # shell para debug
```

## Variáveis de Ambiente (.env)

| Variável | Default | Descrição |
|----------|---------|-----------|
| `GEMINI_API_KEY` | — | Chave Google Gemini (**obrigatório**) |
| `OPENROUTER_API_KEY` | — | Chave OpenRouter (opcional) |
| `MOBILE_NUMBER` | — | Número do bot para Pairing Code (ex: `5531999990000`) |
| `DB_PATH` | `/data/amelie.sqlite` | SQLite da aplicação |
| `BRIDGE_DB_PATH` | `/data/bridge/whatsapp.db` | SQLite da sessão WhatsApp |
| `PORT` | `4000` | Porta HTTP da aplicação |
| `BRIDGE_PORT` | `8080` | Porta interna do bridge (não exposta) |

`WHATSMEOW_URL` e `GLEAM_URL` são definidos automaticamente pelo `entrypoint.sh`
e **não precisam** estar no `.env`.

## Dados e Backup

Todos os dados ficam em `./db/` (mapeado para `/data` no container):

```
db/
├── amelie.sqlite          # histórico, config, prompts, transações
└── bridge/
    └── whatsapp.db        # sessão WhatsApp (não apagar sem re-autenticar)
```

### Backup

```bash
docker-compose exec amelie sh -c \
  "cp /data/amelie.sqlite /data/amelie_backup_\$(date +%Y%m%d).sqlite"
```

### Restore

```bash
docker-compose down
cp amelie_backup_YYYYMMDD.sqlite db/amelie.sqlite
docker-compose up -d
```

## Upgrade

```bash
git pull
docker-compose up -d --build
```

## Troubleshooting

**QR Code expirou:** reinicie o container (`docker-compose restart`).

**Bridge não sobe:** verifique se `BRIDGE_DB_PATH` tem diretório pai com permissão de escrita.

**Banco corrompido:** pare, remova o arquivo `.sqlite` afetado, reinicie (histórico é perdido).
