# Deployment - Amélie Gleam 🚀

## Estrutura do Projeto

```
amelie_gleam/
├── src/                    # Código Gleam (core funcional)
├── whatsmeow-bridge/       # Bridge Go para WhatsApp
├── db/                     # SQLite databases (persistência)
├── docker-compose.yml      # Orquestração dos serviços
├── Dockerfile             # Build do app Gleam
├── .env.example           # Template de configuração
└── .env                   # Suas chaves (NÃO commitar!)
```

## Deploy com Docker Compose (Recomendado)

### Pré-requisitos
- Docker e Docker Compose instalados
- Chave API do Google Gemini (obtenha em [Google AI Studio](https://aistudio.google.com))

### Passo a Passo

1. **Clone e prepare o ambiente:**
```bash
cd amelie_gleam
cp .env.example .env
nano .env  # Edite GEMINI_API_KEY
```

2. **Inicie os containers:**
```bash
docker-compose up -d --build
```

3. **Verifique os logs:**
```bash
# Logs da bridge
docker-compose logs -f whatsmeow-bridge

# Logs do app Gleam
docker-compose logs -f amelie-gleam
```

4. **Conecte o WhatsApp:**
   - O bridge exibirá um QR Code nos logs
   - Escaneie com seu WhatsApp em "Aparelhos Conectados"

### Comandos Úteis

```bash
# Parar os containers
docker-compose down

# Reiniciar
docker-compose restart

# Verificar status
docker-compose ps

# Atualizar após mudanças no código
docker-compose up -d --build

# Entrar no container para debug
docker-compose exec amelie-gleam sh
docker-compose exec whatsmeow-bridge sh
```

## Estrutura de Serviços

| Serviço | Porta | Função | Persistência |
|---------|-------|--------|--------------|
| **whatsmeow-bridge** | 8080 | Conexão WhatsApp | `./whatsmeow-bridge/db/` |
| **amelie-gleam** | 4000 | Core bot (IA, lógica) | `./db/` |

## Variáveis de Ambiente

| Variável | Descrição | Obrigatório |
|----------|-----------|-------------|
| `GEMINI_API_KEY` | Chave API do Google Gemini | ✅ Sim |
| `OPENROUTER_API_KEY` | Chave API do OpenRouter (opcional) | ❌ Não |
| `DB_PATH` | Caminho do SQLite | ❌ (default: `/data/amelie.sqlite`) |
| `PORT` | Porta HTTP | ❌ (default: `4000`) |
| `WHATSMEOW_URL` | URL do bridge | ❌ (gerenciado pelo docker-compose) |

## Debug de Problemas Comuns

### Bridge não conecta ao WhatsApp
- Verifique os logs: `docker-compose logs whatsmeow-bridge`
- Escaneie o QR Code novamente se a sessão expirou
- O bridge precisa ser conectado **antes** do app Gleam

### App Gleam não responde
- Verifique se o bridge está rodando: `docker-compose ps`
- Verifique logs: `docker-compose logs amelie-gleam`
- Certifique-se de que `WHATSMEOW_URL` está correto

### Erro de banco de dados
- Garanta que o diretório `./db/` tem permissões de escrita
- Se corrompido, pare os containers, remova `db/*.sqlite` e reinicie

## Backup e Restore

### Backup dos dados
```bash
# Backup banco Gleam
docker-compose exec amelie-gleam sh -c "cp /data/amelie.sqlite /data/backup_$(date +%Y%m%d).sqlite"

# Backup sessão WhatsApp
docker-compose exec whatsmeow-bridge sh -c "cp /app/db/*.db /app/db/backup_$(date +%Y%m%d).db"

# Copiar para host
docker cp amelie-gleam:/data/backup_YYYYMMDD.sqlite ./
```

### Restore
```bash
# Parar containers
docker-compose down

# Restaurar bancos
cp backup_YYYYMMDD.sqlite db/amelie.sqlite
cp whatsmeow_bridge_backup_YYYYMMDD.db whatsmeow-bridge/db/whatsmeow.db

# Reiniciar
docker-compose up -d
```

## Upgrade

```bash
# Pull das mudanças do código
git pull

# Rebuild e reiniciar
docker-compose up -d --build
```

## Atualização dos Achados (Pós-Migração)

Após mover o whatsmeow-bridge para dentro de amelie_gleam:

✅ **Benefícios:**
- **Simplificado:** Agora é **um repositório único** com tudo
- **Docker Compose:** `docker-compose up` inicia tudo de uma vez
- **Networking:** Services na mesma rede `amelie-net`
- **Deploy simplificado:** Não precisa gerenciar dois repositórios separadamente
- **Versão sincronizada:** Bridge e app Gleam sempre em versão compatível

✅ **Pegada Total (com bridge interno):**
- **Amélie Gleam (com bridge):** 77 MB (49 + 28)
- **Amélie (Node.js):** 265 MB
- **Ainda 3.4x menor!** 🎉
