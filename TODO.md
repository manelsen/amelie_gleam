# TODO: Paridade `amelie` -> `amelie_gleam`

Este arquivo lista funcionalidades que existem em `~/git/amelie` e ainda nao
estao disponiveis aqui, ou estao apenas parcialmente implementadas.

## Ja presentes aqui

Nao entram no TODO de paridade:

- Comandos `.ajuda`, `.reset`, `.audio`, `.imagem`, `.video`, `.doc`,
  `.legenda`, `.longo`, `.curto`, `.cego`
- Processamento de texto, imagem, audio, video e documento
- Persistencia em SQLite para config, historico, prompts, usuarios, grupos e
  transacoes
- Bridge WhatsApp com QR Code e Pairing Code
- Dispatcher multi-provider no backend (`gemini` + `openrouter`)

## Lacunas mapeadas

### 1. Comandos do legado ainda ausentes no chat

- [x] ~~`.prompt`~~ — vetado (abuso pelos usuários; futuro: CLI admin)
- [x] ~~`.config`~~ — vetado (abuso pelos usuários; futuro: CLI admin)
- [x] ~~`.users`~~ — vetado via chat; futuro: CLI admin
- [x] ~~`.filas`~~ — vetado via chat; futuro: CLI admin

Notas:

- O legado registra esses comandos em
  `/home/micelio/git/amelie/src/adaptadores/whatsapp/comandos/RegistroComandos.js`
- Aqui ja existem acoes internas para prompts, usuarios, grupos e metricas, mas
  o dispatcher ainda nao expoe isso no WhatsApp

### 2. Paridade incompleta de configuracao operacional

- [x] Expor selecao de `provedor` e `modelo` por comando, com persistencia por
  chat (`.modelo provedor/modelo`)
- [x] Corrigir bootstrap de providers: path ja era `.yaml`; TODO era obsoleto
- [x] Conectar `providers_config` ao fluxo: `AlterarModelo` valida via
  `providers_config.validar_modelo` no shell

### 3. Resiliencia de entrega ainda abaixo do legado

- [x] Fechar o ciclo de auditoria transacional:
  registrar -> enviar -> marcar entregue/falha (`shell/entrega_auditada.gleam`)
- [x] Usar o `id` retornado por `transacao_sqlite.registrar/1` no fluxo real
- [x] Acionar `fila_offline.ProcessarPendentes` periodicamente
  (`fila_offline.agendar_processamento` chamado em `amelie_gleam.gleam`)
- [x] Enfileirar falhas de envio para retry automatico
- [ ] Preservar contexto da resposta pendente (snapshot da mensagem original)

### 4. Comportamentos de UX do legado ainda faltantes

- [x] Implementar resposta citando a mensagem original (`entregar` no handler,
  `enviar_citando` em entrega_auditada, bridge Go com ContextInfo)
- [x] Fallback para envio simples quando `message_id` ausente (sem citacao)
- [x] Implementar leitura implicita de URLs em mensagens de texto
  (`url_scraper`, `BuscarUrlEResponder`, `builder.montar_com_url`)

### 5. Resiliencia de IA ainda inferior ao Node

- [x] Retry com backoff exponencial (max 3 tentativas, 1s/2s/4s) para erros
  transientes (429, 503, ErroComunicacao) — `shell/ia_resiliente.gleam`
- [x] Circuit breaker por provedor (5 falhas → Aberto 60s → SemiAberto) —
  `shell/circuit_breaker.gleam`
- [x] Cache de respostas (SHA256 de prompt+modelo, TTL 1h, max 500) —
  `shell/cache_ia.gleam`; integrado em `ia_resiliente.envolver`
- [ ] Rate limiting — BEAM lida bem com concorrencia nativa; baixa prioridade

### 6. Operacao e manutencao

- [x] Rotina periodica de limpeza de transacoes antigas (entregue/descartada
  com +7 dias) — `shell/manutencao.gleam`, roda a cada 6h
- [ ] Limpeza de arquivos temporarios de video ja processados (Google File API)
  — fila_midia ja chama deletar_arquivo; verificar se ha casos perdidos
- [ ] Expor estado operacional (filas, CB status) via endpoint /status
- [x] Telemetria de memoria/recursos BEAM — `metricas.formatar` agora inclui
  memoria total, memoria de processos e contagem de processos via FFI

## Prioridade sugerida

### P0

_Concluído — ver seção 3._

### P1 — Concluído

- [x] Citacao de resposta + fallback de contexto
- [x] Leitura implicita de URLs
- [x] Corrigir `providers_config` externo + comando `.modelo`

### P2

- [ ] Circuit breaker, cache e rate limiting na camada de IA
- [ ] Telemetria e rotinas de manutencao

## Referencias de comparacao

- Legado Node:
  `/home/micelio/git/amelie/src/adaptadores/whatsapp/comandos/RegistroComandos.js`
- Comando `.prompt`:
  `/home/micelio/git/amelie/src/adaptadores/whatsapp/comandos/implementacoes/ComandoPrompt.js`
- Comando `.config`:
  `/home/micelio/git/amelie/src/adaptadores/whatsapp/comandos/implementacoes/ComandoConfig.js`
- Comando `.users`:
  `/home/micelio/git/amelie/src/adaptadores/whatsapp/comandos/implementacoes/ComandoUsers.js`
- Comando `.filas`:
  `/home/micelio/git/amelie/src/adaptadores/whatsapp/comandos/implementacoes/ComandoFilas.js`
- Resiliencia de envio:
  `/home/micelio/git/amelie/src/servicos/ServicoMensagem.js`
- Notificacoes pendentes:
  `/home/micelio/git/amelie/src/adaptadores/whatsapp/GerenciadorNotificacoes.js`
- IA resiliente:
  `/home/micelio/git/amelie/src/adaptadores/ai/GerenciadorAI.js`
- URLs em texto:
  `/home/micelio/git/amelie/src/adaptadores/whatsapp/processadores/ProcessadorTexto.js`
