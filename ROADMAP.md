# ROADMAP: Amélie Gleam

## Visão Geral
Amélie Gleam é a reescrita da bot Amélie original de Node.js em **Gleam** (runtime BEAM/Erlang), utilizando uma arquitetura **Hexagonal (Ports & Adapters)** rigorosa e um **Functional Core** puro.

---

## 🚀 Progresso Atual

### Fase 0: Fundação ✅
- Setup do projeto Gleam com `gleam news`.
- Implementação do `whatsmeow-bridge` em Go.
- Definição dos tipos de domínio fundamentais.

### Fase 1: Core & Mensagens ✅
- Processador de texto funcional.
- Integração básica com Google Gemini e WhatsApp.
- Persistência básica de configuração e histórico em SQLite.

### Fase 2: Mídia & Logging ✅
- Processamento assíncrono de Imagem, Áudio, Vídeo e Documento (Atores OTP).
- Logging detalhado de eventos de processamento.
- Paridade de comandos básicos (`.audio`, `.video`, `.imagem`, etc).

### Fase 3: Paridade Final & Resiliência 🏗️ (Em Progresso)
- **Fase I: Grupos** ✅ — Registro e listagem de grupos funcional via Webhook + SQLite.
- **Fase J: Transações** 🏗️ — Auditoria de entrega de mensagens via banco.
- **Fase K: Fila Offline** 🏗️ — Retries automáticos para falhas.
- **Fase L: Maintenance** 🏗️ — Snapshot de histórico e limpeza.

---

## 🛠️ Arquitetura

O projeto é guiado por três princípios:
1. **Core Puro:** A lógica de negócio (`core/`) não conhece efeitos colaterais.
2. **Ports & Adapters:** Todo recurso externo (IA, Whatsapp, SQLite) é acessado através de uma porta (`portas/`).
3. **Efeitos na Borda:** O shell (`shell/`) é responsável por orquestrar e executar os efeitos.

### Novo Plano: Multi-IA (Agnóstico)
Planejamos evoluir a arquitetura para suportar múltiplos provedores de IA (OpenRouter, Mistral) através de um `ia_dispatcher` dinâmico, permitindo que cada chat escolha sua "inteligência" preferida.

---

## 📅 Próximos Passos (Próximos 3-6 Meis)

- **Q2 2026:** Finalizar paridade 100% com o legado Node.js.
- **Q3 2026:** Iniciar suporte **Multi-canal** (Telegram e WhatsApp simultâneos).
- **Q4 2026:** Expansão de ferramentas (Plugins) e integração com modelos locais via Ollama.
