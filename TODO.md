# TODO: Amélie Gleam

## Paridade de Funcionalidades (Amélie Node)

### Fase I: Gerenciamento de Grupos ✅
- [x] Registro automático de grupos no `handler_mensagem`
- [x] Comando `.grupos` no dispatcher
- [x] Adaptador `grupo_sqlite`
- [x] Testes de integração para grupos

### Fase J: Transações e Auditoria
- [ ] Criar `TransacaoPorta`
- [ ] Implementar `transacao_sqlite` (tabela: `transacoes`)
- [ ] Atualizar handler para usar transações em todos os disparos de mensagens
- [ ] Garantir auditoria de "entregue"

### Fase K: Resiliência (Fila Offline)
- [ ] Implementar ator OTP `fila_offline` para retentativas de transações pendentes/falhas
- [ ] Configurar timers de retry com backoff ou intervalo fixo

### Fase L: Manutenção e Snapshot
- [ ] Implementar lógica de domínio para detectar expiração de histórico
- [ ] Adicionar ação `SnapshotHistorico`
- [ ] Implementar compactação de histórico via IA e limpeza no banco

## Infraestrutura & IA

### Fase M: Multi-Provedor AI (Agnóstico)
- [ ] Evoluir `IAPorta` para suportar argumentos de provedor/modelo
- [ ] Implementar `ia_dispatcher` (Roteador de adapters)
- [ ] Criar adaptador `openrouter_http`
- [ ] Permitir configuração de `provedor` per-chat no SQLite

## Futuro
- [ ] **Multi-canal:** Suporte para Telegram (usando as mesmas portas de IA/Config/Histórico)
- [ ] Monitoramento via dashboard (métricas OTP)
- [ ] Suporte a plugins/ferramentas para a IA (Functions/Tools)

## Bugs & Refatoração
- [x] Corrigir erros de compilação em `handler_mensagem.gleam`
- [x] Corrigir arity em testes (`fixtures.gleam`)
- [ ] Migrar FFI Erlang para Gleam puro onde possível (ex: `simplifile` se disponível)
