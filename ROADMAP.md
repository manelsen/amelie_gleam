# ROADMAP: Amélie Gleam

> Atualizado em 13 de setembro de 2026.

## Visão geral

Amélie é um bot multimodal escrito em Gleam sobre BEAM/Erlang, com um bridge Go
baseado em whatsmeow para integração com WhatsApp. O projeto segue arquitetura
hexagonal: domínio e core puros, contratos em `portas/`, integrações em
`adaptadores/` e coordenação de efeitos em `shell/`.

O projeto já ultrapassou a etapa de paridade básica com o legado. O foco atual é
transformar as funcionalidades existentes em uma operação previsível: sessão do
WhatsApp diagnosticável, concorrência controlada, retries seletivos e cobertura
de integração entre os processos Gleam e Go.

## Estado atual

### 1. Fundação e core ✅

- Domínio tipado para mensagens, ações, mídia, configuração, erros e transações.
- Core funcional puro para validação, comandos, construção de prompts e decisão
  das ações a executar.
- Semântica explícita entre `GerarEEnviar`, que chama IA, e `EnviarResposta`, que
  entrega texto pronto.
- Histórico e configuração por chat persistidos em SQLite.
- Comandos com ou sem ponto, normalização de acentos e configurações de mídia,
  legenda, acessibilidade, tamanho da resposta e modelo.
- Detecção de URLs separadas por whitespace, incluindo links em linha própria.

### 2. IA e resiliência 🟡

- Dispatcher para múltiplos provedores: Google Gemini e OpenRouter.
- Seleção de provedor e modelo por chat.
- `gemini-3.8-flash` como modelo padrão e na compactação de histórico.
- Migração automática de configurações no antigo padrão
  `gemini-3.1-flash-lite`; escolhas explícitas por outros modelos são preservadas.
- Processamento de texto, imagem, áudio, vídeo e documentos.
- Upload e polling de arquivos pela Gemini File API.
- Cache de respostas por prompt/modelo com TTL e limite de entradas.
- Retry com backoff exponencial e circuit breaker separado por provedor.
- Exclusão de arquivos remotos mantida fora de retry e circuit breaker por ser
  uma operação best-effort.

### 3. WhatsApp e mídia 🟡

- Bridge Go atualizado para uma versão de agosto de 2026 do whatsmeow, com os
  breaking changes absorvidos.
- Recebimento e envio de mensagens, respostas citadas e reações.
- Suporte a JIDs LID e persistência do dispositivo/sessão pelo whatsmeow.
- Filas OTP independentes para imagem, áudio, vídeo, documento e sticker.
- Media retry para arquivos expirados ou temporariamente indisponíveis.
- Stickers estáticos, animados, thumbnail e fallback textual quando a mídia não
  pode ser recuperada.
- Vídeos enviados como mídia e links de YouTube, Instagram e TikTok processados
  via `yt-dlp`.
- Fila persistente entre bridge e webhook Gleam.
- Replay de `HistorySync` desativado no bridge; filtro de idade e deduplicação
  continuam protegendo o handler Gleam.
- Falhas de conexão registradas por evento e propagadas de ponta a ponta:
  whatsmeow → bridge → HTTP estruturado → adaptador Gleam → log da aplicação.
- `/health`, `/send` e `/react` distinguem sessão ausente, logout, desconexão,
  stream substituído, cliente desatualizado, banimento temporário e falha da
  operação.

### 4. Persistência e operação 🟡

- Auditoria de entregas e reações em SQLite.
- Fila offline com limite de tentativas e descarte explícito.
- Registro de mensagens recebidas para deduplicação.
- Limpeza periódica de transações antigas.
- Registro automático de usuários e grupos.
- Executor de snapshot para históricos longos implementado, ainda sem comando ou
  agendamento que o acione.
- Métricas em memória para mensagens, erros e mídia processada, ainda sem endpoint
  ou comando público de consulta.
- Dockerfile multi-stage, Docker Compose, volumes persistentes e rotação de logs.

### 5. Capacidades parcialmente conectadas 🟡

- Telegram conectado para texto e comandos 1-a-1 via webhook (/webhook/telegram) e roteador multicanal (Etapa 1 concluída). Mídias assíncronas do Telegram seguem nas Etapas 2 e 3.
- Persistência e executores de prompts nomeados implementados, mas ainda não
  expostos pelo dispatcher de comandos.
- Ações para consultar métricas, usuários, grupos e executar snapshot existem no
  shell, mas não são produzidas pelo core atual.

## Validação atual

- 140 testes Gleam passando.
- Testes, race detector, `go vet` e build do bridge Go passando.
- Testes de regressão para HistorySync, estado de sessão, respostas HTTP de erro,
  migração de modelo, URLs com newline/tab, filas e handlers.

## Próximas prioridades

### P0 — Confiabilidade operacional

- [ ] Tornar o estado de sessão visível no healthcheck da aplicação Gleam e no
  healthcheck do container, não apenas no bridge.
- [ ] Classificar erros da fila offline em transitórios e definitivos; logout,
  sessão removida e payload inválido não devem consumir retries idênticos a uma
  indisponibilidade temporária.
- [ ] Cobrir reconexão automática, logout 401, novo pareamento e stream substituído
  com testes de integração do ciclo de vida do bridge.
- [ ] Adicionar teste end-to-end entre webhook, processamento, IA fake, auditoria e
  envio pelo bridge fake.
- [ ] Definir procedimento operacional documentado para backup, recuperação e novo
  pareamento sem apagar dados não relacionados à sessão.

### P1 — Concorrência e observabilidade

- [ ] Corrigir o estado semiaberto do circuit breaker para permitir uma única
  chamada de prova; hoje chamadas concorrentes podem atravessá-lo juntas.
- [ ] Avaliar a retirada de `process.call` síncrono do caminho quente do circuit
  breaker ou medir sua contenção sob carga das filas de mídia.
- [ ] Adicionar métricas de latência, retries, estado do circuit breaker, tamanho
  das filas e motivo da indisponibilidade do WhatsApp.
- [ ] Padronizar logs estruturados e incluir identificadores de mensagem,
  transação e operação para correlação completa.
- [ ] Definir timeouts por operação externa e propagar a causa original em todos
  os adaptadores, seguindo o padrão já aplicado ao whatsmeow.
- [ ] Expor de forma autenticada as métricas, consultas administrativas e snapshot
  que já possuem executores no shell.

### P2 — Multi-canal

- [x] **Etapa 1 (Texto, Comandos e Roteamento Multicanal — Concluída):**
  - Webhook de updates do Telegram (`POST /webhook/telegram`) com validação opcional de secret token.
  - Bloqueio estrito e sistemático de grupos no Telegram (`chat.type != "private"` é descartado).
  - Roteador multicanal (`roteador_mensageiro`) selecionando `MensageiroPorta` por prefixo de `chat_id` (`tg:` vs WhatsApp) sem duplicar core ou handlers.
  - Normalização de comandos com barra (`/start`, `/ajuda`, `/cego`, `/curto`, etc.) e suporte a menção do bot em comandos.
  - Cobertura completa com testes automatizados de decodificação, roteamento e fluxo end-to-end.
- [x] **Etapa 2 (Fotos e Áudio/Voz — Concluída):**
  - Download assíncrono e não-bloqueante de fotos (alta resolução) e áudios/mensagens de voz via Telegram Bot API (`getFile` + `baixar_arquivo`).
  - Suporte a legendas (`caption`) em fotos e áudios integradas ao contexto da mensagem.
  - Encaminhamento direto para as filas OTP existentes em `fila_midia.gleam` e pipeline multimodal do Gemini.
  - Rejeição categórica de mídias recebidas em grupos do Telegram.
- [x] **Etapa 3 (Documentos, Figurinhas, Vídeos até 20MB e Chat Actions — Concluída):**
  - [x] Suporte a vídeos (`video`, `video_note`, `animation` e vídeos enviados como documentos) até 20MB via Bot API com download assíncrono e fila OTP de vídeo.
  - [x] Mapeamento compatível de reações (`⌛`/`⏳` -> `🤔` e `🆗` -> `👍`) com feedback visual imediato ao usuário.
  - [x] Suporte a documentos genéricos (PDFs, TXT, DOCX, etc.) até 20MB integrados à fila OTP de documentos e pipeline multimodal do Gemini.
  - [x] Suporte a figurinhas/stickers estáticos e em vídeo (`image/webp` e `video/webm`) integrados à fila OTP de figurinhas e contexto de emoji associado.
  - [x] Indicadores de presença em tempo real via Telegram Bot API (`sendChatAction` com `typing`, `upload_photo`, `upload_voice`, `upload_video`, `upload_document`, `choose_sticker`).
  - [x] Rejeição categórica de qualquer mídia, documento ou figurinha recebido em grupos do Telegram.

### P3 — Evolução de produto

- [ ] Decidir se a seleção de modelos antigos/OpenRouter continuará exposta por
  chat ou se produção ficará restrita ao `gemini-3.8-flash`.
- [ ] Evoluir o scraper de URLs para extração de conteúdo mais robusta e segura.
- [ ] Expor os prompts nomeados já persistidos ou remover a infraestrutura que não
  fizer parte do produto.
- [ ] Adicionar plugins/ferramentas com permissões e limites explícitos.
- [ ] Avaliar modelos locais via Ollama depois de estabilizar observabilidade e
  operação multi-canal.

## Critério para a próxima etapa

A fase de endurecimento operacional estará concluída quando perda de sessão,
falhas temporárias e erros definitivos produzirem comportamentos distintos e
observáveis; quando o fluxo principal estiver coberto por um teste end-to-end; e
quando o circuit breaker e as filas tiverem métricas suficientes para validar seu
comportamento sob concorrência.
