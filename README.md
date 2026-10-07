# Amélie — WhatsApp Multimodal Bot (Gleam / BEAM)

Amélie é uma assistente inteligente para WhatsApp construída em **[Gleam](https://gleam.run/)** sobre a máquina virtual **Erlang/OTP (BEAM)**, integrando-se ao ecossistema do WhatsApp através de um bridge local de alto desempenho em **Go** ([whatsmeow](https://github.com/tulir/whatsmeow)) e provedores de Inteligência Artificial multimodal de ponta (**Google Gemini** e **OpenRouter**).

O projeto adota rigorosamente os princípios de **Arquitetura Hexagonal (Ports & Adapters)** com um **Functional Core puro**, garantindo separação absoluta entre regras de negócio determinísticas e efeitos colaterais de I/O.

---

## ✨ Funcionalidades Principais

- 💬 **Texto Conversacional:** Respostas contextuais com histórico persistente por conversa em SQLite e compactação automática de contexto longo.
- 🎙️ **Transcrição de Áudio:** Processamento de mensagens de voz e arquivos de áudio via Gemini, com sanitização de timestamps.
- 🖼️ **Visão Computacional e Audiodescrição:** Interpretação visual com modos conciso (`.curto`), detalhado (`.longo`) ou de acessibilidade para pessoas com deficiência visual (`.cego`).
- 🎬 **Vídeos e Redes Sociais:**
  - Análise e audiodescrição de vídeos enviados diretamente no chat.
  - Extração e análise automática de links de vídeo do **YouTube (Shorts/Live)**, **Instagram (Reels)** e **TikTok** via `yt-dlp`.
- 🎭 **Figurinhas e Stickers:**
  - Suporte nativo a figurinhas estáticas (WebP).
  - Processamento de figurinhas animadas via conversão cronológica para vídeo MP4 (Python PIL + `ffmpeg`) ou grade de quadros (*contact sheet* via `webpmux`/`dwebp`).
  - Fallback por metadados quando o arquivo de figurinha já expirou nos servidores do WhatsApp.
- 📄 **Leitura de Documentos:** Análise e resumo estruturado de documentos e PDFs.
- 🌐 **Leitura de Links:** Extração de conteúdo textual de páginas web compartilhadas no chat.
- 🛡️ **Resiliência e Tolerância a Falhas:**
  - Transações auditadas em SQLite e deduplicação de mensagens recebidas.
  - Fila offline automática com backoff para reenvio de mensagens em instabilidades.
  - Circuit Breaker individual por provedor de IA com estados Fechado, Aberto e SemiAberto.
  - Cache de respostas de IA em memória (SHA-256 de prompt + modelo, TTL 1h).
  - Offload de mídia pesada para disco temporário para evitar limites de buffer HTTP.

---

## 🏛️ Visão da Arquitetura

```text
src/
├── dominio/          # Tipos puros: Mensagem, Acao, Config, Erro, Transacao
├── core/             # Lógica pura: processador, validacao, comandos, prompt builder
├── portas/           # Interfaces abstratas: Mensageiro, IA, Config, Historico, Transacao
├── adaptadores/      # Implementações concretas de I/O: whatsmeow, Gemini, OpenRouter, SQLite
├── shell/            # Orquestração com efeitos: atores OTP, filas de mídia, circuit breaker
├── amelie_gleam_ffi.erl # FFI Erlang (variáveis de ambiente, IO de arquivos, métricas BEAM)
└── amelie_gleam.gleam   # Ponto de entrada e servidor HTTP Mist (:4000)
whatsmeow-bridge/     # Microserviço em Go para conexão com WhatsApp (:8080)
```

---

## 🚀 Como Executar

### 1. Usando Docker Compose (Recomendado)

O projeto possui build unificado em um único container multi-stage contendo o runtime Erlang/Gleam, o bridge Go compilado, `ffmpeg`, `yt-dlp` e `libwebp-tools`:

```bash
# Copie o template de ambiente
cp .env.example .env

# Configure suas chaves de API (pelo menos GEMINI_API_KEY)
nano .env

# Inicie o serviço unificado
docker compose up -d --build

# Acompanhe os logs para parear via QR Code ou Pairing Code
docker compose logs -f
```

### 2. Desenvolvimento Local

#### Pré-requisitos
- [Gleam](https://gleam.run/) (v1.15+) e Erlang/OTP 26+
- [Go](https://go.dev/) (v1.24+)
- SQLite3, `ffmpeg`, Python 3 + Pillow, `libwebp-tools` e `yt-dlp`

```bash
# 1. Instalar dependências Gleam
gleam deps download

# 2. Rodar a suíte de testes do Gleam
gleam test

# 3. Rodar a suíte de testes do bridge Go
cd whatsmeow-bridge && go test -count=1 ./... && cd ..

# 4. Executar localmente
GEMINI_API_KEY=sua_chave WHATSMEOW_URL=http://localhost:8080 DB_PATH=./db/amelie.sqlite PORT=4000 gleam run
```

---

## 🤖 Comandos Disponíveis no Chat

Envie no WhatsApp para o bot:

| Comando | Descrição |
|---|---|
| `.ajuda` | Exibe a lista de comandos disponíveis |
| `.reset` | Limpa histórico de conversa e restaura configurações padrão |
| `.audio on\|off` | Ativa ou desativa a transcrição de mensagens de áudio |
| `.imagem on\|off` | Ativa ou desativa a análise de imagens |
| `.video on\|off` | Ativa ou desativa a análise de vídeos |
| `.doc on\|off` | Ativa ou desativa a análise de documentos |
| `.legenda` | Alterna entre transcrição literal e descrição detalhada de vídeo |
| `.longo` | Configura modo de audiodescrição detalhada |
| `.curto` | Configura modo de audiodescrição concisa |
| `.cego` | Ativa perfil de acessibilidade para deficientes visuais |
| `.modelo` | Consulta o provedor e modelo ativos no chat |
| `.modelo provedor/modelo` | Altera o modelo (ex: `.modelo gemini/gemini-2.5-pro` ou `.modelo gemini/gemini-3.8-flash`) |

---

## 📚 Documentação Complementar

- [DEPLOYMENT.md](file:///home/micelio/git/amelie_gleam/DEPLOYMENT.md) — Guia operacional detalhado, volumes, variáveis de ambiente e backups.
- [ROADMAP.md](file:///home/micelio/git/amelie_gleam/ROADMAP.md) — Estado atual de validação, capacidades implementadas e prioridades P0–P3.
- [GEMINI.md](file:///home/micelio/git/amelie_gleam/GEMINI.md) — Especificação técnica da arquitetura, ciclo de vida e convenções.
- [CLAUDE.md](file:///home/micelio/git/amelie_gleam/CLAUDE.md) — Diretrizes de desenvolvimento, regras de trabalho e notas de compilação.
- [AGENTS.md](file:///home/micelio/git/amelie_gleam/AGENTS.md) — Padrões de código, testes e boas práticas para agentes e mantenedores.
- [TODO.md](file:///home/micelio/git/amelie_gleam/TODO.md) — Matriz de paridade histórica em relação ao projeto legado Node.js.
