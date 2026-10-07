# Deployment — Amélie Gleam

## Estrutura de Arquivos

```text
amelie_gleam/
├── src/                    # Código Gleam (core funcional, portas, adaptadores, shell)
├── whatsmeow-bridge/       # Bridge Go (conectividade WhatsApp via whatsmeow)
├── config/                 # Configuração externa de provedores (providers.yaml)
├── cookies/                # Cookies opcionais do yt-dlp (ex: instagram.txt)
├── db/                     # Volume persistente (SQLite da aplicação + sessão WhatsApp)
├── Dockerfile              # Imagem unificada multi-stage (bridge + app + ffmpeg + yt-dlp)
├── entrypoint.sh           # Inicializa bridge em background e Gleam em foreground
├── docker-compose.yml      # Definição do serviço unificado
├── .env.example            # Template de variáveis de ambiente
└── .env                    # Variáveis locais e chaves de API (NÃO commitar!)
```

## Deploy

### Pré-requisitos
- Docker Engine e Docker Compose (plugin v2 ou binário integrado).

### Passo a Passo

```bash
# 1. Copiar o template de variáveis de ambiente
cp .env.example .env

# 2. Editar o arquivo .env com suas chaves de API
nano .env

# 3. (Opcional) Criar diretório de cookies se for utilizar download de mídias restritas do Instagram
mkdir -p cookies

# 4. Construir e iniciar os containers em background
docker compose up -d --build
```

### Conectar o WhatsApp

O bridge whatsmeow exibe o QR Code ou utiliza Pairing Code diretamente nos logs:

```bash
docker compose logs -f
```

- **Via QR Code:** Abra o WhatsApp → *Aparelhos Conectados* → *Conectar um aparelho* e escaneie o código gerado no terminal.
- **Via Pairing Code:** Defina a variável `MOBILE_NUMBER` no seu `.env` com seu número completo (ex: `5531999990000`) e confirme o código de pareamento no celular.

### Comandos Úteis

```bash
docker compose logs -f          # Acompanhar logs em tempo real
docker compose restart          # Reiniciar o serviço
docker compose down             # Parar o serviço
docker compose up -d --build    # Rebuild e reinicialização
docker compose exec amelie sh   # Acessar shell interno para depuração
```

## Variáveis de Ambiente (`.env`)

| Variável | Default | Descrição |
|---|---|---|
| `GEMINI_API_KEY` | — | Chave da Google Gemini API (**obrigatório**) |
| `OPENROUTER_API_KEY` | — | Chave OpenRouter (opcional para modelos adicionais) |
| `MOBILE_NUMBER` | — | Número de telefone para Pairing Code (ex: `5531999990000`) |
| `DB_PATH` | `/data/amelie.sqlite` | Caminho do SQLite da aplicação Gleam |
| `BRIDGE_DB_PATH` | `/data/bridge/whatsapp.db` | Caminho do SQLite de sessão do WhatsApp |
| `PORT` | `4000` | Porta HTTP da aplicação Gleam (exposta externamente como `4001`) |
| `BRIDGE_PORT` | `8080` | Porta interna do bridge whatsmeow (não exposta publicamente) |
| `OFFLINE_RETRY_INTERVAL_MS`| `30000` | Intervalo em milissegundos para reprocessamento de mensagens offline |
| `YTDLP_COOKIES_PATH` | — | Caminho interno do arquivo de cookies Netscape (ex: `/cookies/instagram.txt`) |

> [!NOTE]
> `WHATSMEOW_URL` e `GLEAM_URL` são injetados automaticamente pelo script [`entrypoint.sh`](file:///home/micelio/git/amelie_gleam/entrypoint.sh) e não precisam ser declarados no `.env`.

## Dados, Volumes e Backup

Todos os dados persistentes ficam montados no volume `./db/` (mapeado para `/data` dentro do container):

```text
db/
├── amelie.sqlite          # Banco da aplicação: configs de chat, histórico, prompts, transações
└── bridge/
    └── whatsapp.db        # Banco da sessão do whatsmeow (chave criptográfica do aparelho)
```

### Backup do Banco de Dados

```bash
docker compose exec amelie sh -c \
  "cp /data/amelie.sqlite /data/amelie_backup_\$(date +%Y%m%d).sqlite"
```

Para incluir a sessão do WhatsApp, faça backup de toda a pasta `db/`:

```bash
tar -czvf backup_amelie_$(date +%Y%m%d).tar.gz db/
```

### Restauração

```bash
docker compose down
tar -xzvf backup_amelie_YYYYMMDD.tar.gz
docker compose up -d
```

## Resolução de Problemas (Troubleshooting)

1. **Sessão desconectada ou erro 401 (`whatsapp_logged_out`):**
   O WhatsApp revogou o token do aparelho. Pare o container, remova `db/bridge/whatsapp.db` e inicie novamente para parear um novo QR Code ou Pairing Code.
2. **Erro de DNS em downloads de mídia (`a.whatsapp.net`):**
   O `docker-compose.yml` já inclui `extra_hosts: ["a.whatsapp.net:57.144.249.32"]` para contornar falhas de resolução dos domínios MMS do WhatsApp em certas redes e provedores.
3. **Verificação de Saúde (Healthcheck):**
   - Aplicação Gleam: `curl http://localhost:4001/health` (retorna `{"status":"ok"}`).
   - Bridge whatsmeow (via shell do container): `curl http://localhost:8080/health` (retorna status e detalhe da conexão WhatsApp).
4. **Erros de download no Instagram / YouTube:**
   Para conteúdo que requer login ou restrição de idade, exporte os cookies do navegador em formato Netscape, salve em `./cookies/instagram.txt` e configure `YTDLP_COOKIES_PATH=/cookies/instagram.txt`.
