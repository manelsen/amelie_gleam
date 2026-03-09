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

- [ ] Implementar comando `.prompt` com paridade funcional:
  `set`, `get`, `list`, `use`, `clear`, `delete`
- [ ] Implementar comando `.config` com `get` e `set` para configuracoes por
  chat
- [ ] Implementar comando `.users` para listar participantes do grupo atual
- [ ] Implementar comando `.filas` para operacao administrativa das filas
  (`status`, `limpar`, etc.)

Notas:

- O legado registra esses comandos em
  `/home/micelio/git/amelie/src/adaptadores/whatsapp/comandos/RegistroComandos.js`
- Aqui ja existem acoes internas para prompts, usuarios, grupos e metricas, mas
  o dispatcher ainda nao expoe isso no WhatsApp

### 2. Paridade incompleta de configuracao operacional

- [ ] Expor selecao de `provedor` e `modelo` por comando, com persistencia por
  chat
- [ ] Corrigir bootstrap de providers:
  `src/amelie_gleam.gleam` tenta ler `./config/providers.json`, mas o repo
  versiona `config/providers.yaml`
- [ ] Conectar `providers_config` de fato ao fluxo de configuracao, em vez de
  cair silenciosamente no padrao

### 3. Resiliencia de entrega ainda abaixo do legado

- [ ] Fechar o ciclo de auditoria transacional:
  registrar -> enviar -> marcar entregue/falha
- [ ] Passar a usar o `id` retornado por `transacao_sqlite.registrar/1` nas
  respostas reais do WhatsApp
- [ ] Acionar `fila_offline.ProcessarPendentes` periodicamente ou em eventos de
  reconexao
- [ ] Enfileirar falhas reais de envio para retry automatico
- [ ] Preservar contexto da resposta pendente, como o legado faz com snapshot da
  mensagem original

Notas:

- Hoje a fila offline eh iniciada, mas nao ha chamada para `ProcessarPendentes`
- O handler registra transacoes, mas nao marca sucesso de entrega nem reusa o
  `id` da transacao no fluxo normal

### 4. Comportamentos de UX do legado ainda faltantes

- [ ] Implementar resposta citando a mensagem original quando possivel
- [ ] Implementar fallback textual de contexto quando a citacao nao for possivel
- [ ] Implementar leitura implicita de URLs em mensagens de texto
  (scraping/resumo do link no contexto enviado para a IA)

### 5. Resiliencia de IA ainda inferior ao Node

- [ ] Adicionar camada equivalente ao `GerenciadorAI` do legado:
  retry com backoff, timeout centralizado e tratamento consistente de falhas
- [ ] Adicionar `circuit breaker` para provedores de IA
- [ ] Adicionar cache de respostas/processamentos repetidos
- [ ] Adicionar limitacao de taxa e concorrencia por provider

### 6. Operacao e manutencao

- [ ] Criar rotina periodica de limpeza de arquivos temporarios
- [ ] Criar rotina de limpeza de transacoes/notificacoes antigas
- [ ] Expor estado operacional das filas e metricas de forma utilizavel
- [ ] Adicionar telemetria de memoria/recursos equivalente ao legado

## Prioridade sugerida

### P0

- [ ] `.prompt`
- [ ] `.config`
- [ ] Fechar auditoria transacional completa
- [ ] Fazer a `fila_offline` realmente processar pendencias

### P1

- [ ] `.users`
- [ ] `.filas`
- [ ] Citacao de resposta + fallback de contexto
- [ ] Leitura implicita de URLs
- [ ] Corrigir `providers_config` externo

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
