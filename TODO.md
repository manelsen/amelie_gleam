# TODO: Paridade `amelie` -> `amelie_gleam`

Este arquivo lista o status de paridade com o sistema legado (`~/git/amelie`), registrando o que já foi implementado, o que foi vetado deliberadamente e os itens operacionais remanescentes.

## Já presentes aqui

Funcionalidades migradas e ativas no `amelie_gleam`:

- **Comandos:** `.ajuda`, `.reset`, `.audio`, `.imagem`, `.video`, `.doc`, `.legenda`, `.longo`, `.curto`, `.cego`, `.modelo [provedor/modelo]`.
- **Processamento Multimodal:**
  - Texto com histórico conversacional.
  - Imagem (descrição concisa e modo longo detalhado).
  - Áudio (transcrição via Gemini com sanitização de timestamps).
  - Vídeo (upload assíncrono na Gemini File API, polling e descrição).
  - Documentos (leitura e resumo de PDFs e arquivos textuais).
  - Figurinhas / Stickers (WebP estático, figurinhas animadas convertidas para MP4 via PIL/ffmpeg ou grade de quadros via `webpmux`/`dwebp`, além de fallback textual por metadados).
  - Links de redes sociais (extração e descrição de vídeos de YouTube, Instagram e TikTok via `yt-dlp`).
- **Persistência SQLite:**
  - Configuração por chat com migração automática para `gemini-3.8-flash`.
  - Histórico de turnos com limite configurável.
  - Auditoria transacional de entregas (`transacoes`) para deduplicação e retry.
  - Registro de usuários, grupos e prompts nomeados.
- **Conectividade WhatsApp:**
  - Bridge Go baseado no `whatsmeow` com pareamento via QR Code e Pairing Code.
  - Respostas citando mensagem original (`ContextInfo`) e reações por emoji.
  - Fila local no bridge em SQLite para entrega persistente ao Gleam.
  - Tráfego de arquivos grandes via disco temporário (`/tmp/amelie_midia_*`).
  - Diagnóstico e propagação de estado de sessão e erros estruturados de conexão (`/health`, `/send`, `/react`).
- **Resiliência e IA:**
  - Dispatcher multi-provedor (`gemini` e `openrouter`).
  - Retry exponencial com jitter para erros transientes de IA.
  - Circuit Breaker por provedor (`Fechado`, `Aberto` 60s, `SemiAberto`).
  - Cache de respostas em memória (SHA-256 de prompt + modelo, TTL 1h, max 500).
  - Limpeza periódica de transações antigas (+7 dias) a cada 6h.
  - Telemetria de memória BEAM e contagem de processos via FFI Erlang.

---

## Status das Lacunas Mapeadas

### 1. Comandos do legado vetados via chat

- [x] ~~`.prompt`~~ — vetado no chat (abuso por usuários; futuro: CLI admin)
- [x] ~~`.config`~~ — vetado no chat (abuso por usuários; futuro: CLI admin)
- [x] ~~`.users`~~ — vetado no chat (futuro: CLI admin)
- [x] ~~`.filas`~~ — vetado no chat (futuro: CLI admin)

### 2. Configuração operacional

- [x] Expor seleção de `provedor` e `modelo` por comando com persistência (`.modelo provedor/modelo`).
- [x] Validação de provedores e modelos a partir de `config/providers.yaml`.
- [x] Migração automática de configurações legadas para o novo padrão `gemini-3.8-flash`.

### 3. Resiliência de entrega

- [x] Ciclo de auditoria transacional completo: registrar → enviar → marcar sucesso/falha (`shell/entrega_auditada.gleam`).
- [x] Fila offline periódica para reenvio com limite de tentativas (`shell/fila_offline.gleam`).
- [x] Classificação de erros de transporte e estruturados do whatsmeow (`src/adaptadores/whatsmeow_http.gleam`).
- [ ] Preservar contexto da resposta pendente caso haja reinício forçado durante chamada síncrona longa.

### 4. UX e mídia

- [x] Resposta citando a mensagem original com fallback automático quando `message_id` for ausente.
- [x] Extração e leitura de URLs em mensagens de texto (`url_scraper.gleam`).
- [x] Suporte completo a figurinhas animadas (conversão para vídeo MP4 ou grade de quadros).
- [x] Fallback de metadados quando mídia de sticker expira no WhatsApp.
- [x] Suporte a links de vídeo (YouTube Shorts/Live, Instagram Reels, TikTok) via `yt-dlp`.

### 5. Resiliência de IA

- [x] Retry com backoff exponencial (max 3 tentativas) para erros transientes (429, 503, ErroComunicacao) — `shell/ia_resiliente.gleam`.
- [x] Circuit breaker por provedor (5 falhas → Aberto 60s → SemiAberto) — `shell/circuit_breaker.gleam`.
- [x] Cache de respostas em memória (SHA-256 de prompt+modelo, TTL 1h, max 500) — `shell/cache_ia.gleam`.
- [ ] Rate limiting granular na borda — baixa prioridade graças ao modelo de concorrência por atores do BEAM.

### 6. Operação e manutenção

- [x] Rotina periódica de limpeza de transações antigas (+7 dias) — `shell/manutencao.gleam`.
- [x] Telemetria de memória e processos do runtime BEAM — `metricas.formatar`.
- [x] Limpeza automática de arquivos temporários de mídia órfãos no bridge Go (`cleanupOrphanMediaFiles`).
- [ ] Exposição de métricas e status operacional via endpoint HTTP autenticado.

---

## Prioridades Atuais

### P0 — Concluído ✅
- Auditoria transacional e fila offline.
- Paridade de mídia (incluindo stickers, vídeos sociais e áudio).
- Propagação de erros de conexão do WhatsApp.

### P1 — Concluído ✅
- Citação de resposta e fallback.
- Detecção e leitura de URLs em mensagens.
- Provedor configurável (`.modelo`) e migração para `gemini-3.8-flash`.
- Circuit Breaker, Cache de IA e telemetria BEAM.

### P2 — Melhorias Operacionais Futuras
- [ ] Tornar estado da sessão do WhatsApp visível no healthcheck raiz da aplicação Gleam.
- [ ] Expor endpoints administrativos/telemetria com autenticação.
- [ ] Canal de entrada Telegram (integração de updates via webhook no mesmo pipeline de domínio).
