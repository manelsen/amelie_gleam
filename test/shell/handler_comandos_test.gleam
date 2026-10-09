// Testes de integração do shell para comandos.
// Verificam que o handler executa corretamente SalvarConfig e LimparHistorico.

import dominio/config
import dominio/mensagem
import gleam/erlang/process
import gleam/string
import gleeunit/should
import helpers/env
import helpers/fixtures
import helpers/portas_fake
import shell/fila_midia
import shell/handler_mensagem.{Portas}
import shell/metricas

fn fila() {
  let assert Ok(f) = fila_midia.iniciar_todas()
  f
}

fn met() {
  let assert Ok(m) = metricas.iniciar()
  m
}

pub fn audio_off_persiste_config_test() {
  let ref = process.new_subject()
  let portas =
    Portas(
      mensageiro: portas_fake.mensageiro_ok(),
      ia_dispatcher: portas_fake.ia_dispatcher_ok("ok"),
      config: portas_fake.config_capturar(ref),
      historico: portas_fake.historico_vazio(),
      fila: fila(),
      prompts: portas_fake.prompt_noop(),
      metricas: met(),
      usuarios: portas_fake.usuario_noop(),
      grupos: portas_fake.grupo_noop(),
      transacoes: portas_fake.transacao_noop(),
      providers_config: portas_fake.providers_config_ok(),
    )
  let msg = fixtures.mensagem_comando("audio", "off")
  let _ = handler_mensagem.handle(msg, portas)

  let assert Ok(nova_cfg): Result(config.Config, _) = process.receive(ref, 1000)
  nova_cfg.audio_ativo |> should.be_false
}

pub fn audio_on_persiste_config_test() {
  let ref = process.new_subject()
  let portas =
    Portas(
      mensageiro: portas_fake.mensageiro_ok(),
      ia_dispatcher: portas_fake.ia_dispatcher_ok("ok"),
      config: portas_fake.config_capturar(ref),
      historico: portas_fake.historico_vazio(),
      fila: fila(),
      prompts: portas_fake.prompt_noop(),
      metricas: met(),
      usuarios: portas_fake.usuario_noop(),
      grupos: portas_fake.grupo_noop(),
      transacoes: portas_fake.transacao_noop(),
      providers_config: portas_fake.providers_config_ok(),
    )
  let msg = fixtures.mensagem_comando("audio", "on")
  let _ = handler_mensagem.handle(msg, portas)

  let assert Ok(nova_cfg): Result(config.Config, _) = process.receive(ref, 1000)
  nova_cfg.audio_ativo |> should.be_true
}

pub fn audio_toggle_sem_argumento_persiste_config_test() {
  let ref = process.new_subject()
  let portas =
    Portas(
      mensageiro: portas_fake.mensageiro_ok(),
      ia_dispatcher: portas_fake.ia_dispatcher_ok("ok"),
      config: portas_fake.config_capturar(ref),
      historico: portas_fake.historico_vazio(),
      fila: fila(),
      prompts: portas_fake.prompt_noop(),
      metricas: met(),
      usuarios: portas_fake.usuario_noop(),
      grupos: portas_fake.grupo_noop(),
      transacoes: portas_fake.transacao_noop(),
      providers_config: portas_fake.providers_config_ok(),
    )
  // config_padrao tem audio_ativo: True; sem argumento, alterna para False
  let msg = fixtures.mensagem_comando("audio", "")
  let _ = handler_mensagem.handle(msg, portas)

  let assert Ok(nova_cfg): Result(config.Config, _) = process.receive(ref, 1000)
  nova_cfg.audio_ativo |> should.be_false
}

pub fn reset_limpa_historico_test() {
  let ref = process.new_subject()
  let portas =
    Portas(
      mensageiro: portas_fake.mensageiro_ok(),
      ia_dispatcher: portas_fake.ia_dispatcher_ok("ok"),
      config: portas_fake.config_ok(fixtures.config_padrao()),
      historico: portas_fake.historico_capturar_limpezas(ref),
      fila: fila(),
      prompts: portas_fake.prompt_noop(),
      metricas: met(),
      usuarios: portas_fake.usuario_noop(),
      grupos: portas_fake.grupo_noop(),
      transacoes: portas_fake.transacao_noop(),
      providers_config: portas_fake.providers_config_ok(),
    )
  let msg = fixtures.mensagem_comando("reset", "")
  handler_mensagem.handle(msg, portas) |> should.be_ok

  let assert Ok(chat_id) = process.receive(ref, 1000)
  chat_id |> should.equal(fixtures.chat_id())
}

pub fn cego_persiste_config_test() {
  let ref = process.new_subject()
  let portas =
    Portas(
      mensageiro: portas_fake.mensageiro_ok(),
      ia_dispatcher: portas_fake.ia_dispatcher_ok("ok"),
      config: portas_fake.config_capturar(ref),
      historico: portas_fake.historico_vazio(),
      fila: fila(),
      prompts: portas_fake.prompt_noop(),
      metricas: met(),
      usuarios: portas_fake.usuario_noop(),
      grupos: portas_fake.grupo_noop(),
      transacoes: portas_fake.transacao_noop(),
      providers_config: portas_fake.providers_config_ok(),
    )
  let msg = fixtures.mensagem_comando("cego", "")
  handler_mensagem.handle(msg, portas) |> should.be_ok

  let assert Ok(nova_cfg): Result(config.Config, _) = process.receive(ref, 1000)
  nova_cfg.imagem_ativo |> should.be_true
  nova_cfg.audio_ativo |> should.be_true
}

// Testes para novos comandos

pub fn longo_persiste_config_test() {
  let ref = process.new_subject()
  let portas =
    Portas(
      mensageiro: portas_fake.mensageiro_ok(),
      ia_dispatcher: portas_fake.ia_dispatcher_ok("ok"),
      config: portas_fake.config_capturar(ref),
      historico: portas_fake.historico_vazio(),
      fila: fila(),
      prompts: portas_fake.prompt_noop(),
      metricas: met(),
      usuarios: portas_fake.usuario_noop(),
      grupos: portas_fake.grupo_noop(),
      transacoes: portas_fake.transacao_noop(),
      providers_config: portas_fake.providers_config_ok(),
    )
  let msg = fixtures.mensagem_comando("longo", "")
  handler_mensagem.handle(msg, portas) |> should.be_ok

  let assert Ok(nova_cfg): Result(config.Config, _) = process.receive(ref, 1000)
  nova_cfg.modo_descricao |> should.equal(config.Longo)
}

pub fn curto_persiste_config_test() {
  let ref = process.new_subject()
  let portas =
    Portas(
      mensageiro: portas_fake.mensageiro_ok(),
      ia_dispatcher: portas_fake.ia_dispatcher_ok("ok"),
      config: portas_fake.config_capturar(ref),
      historico: portas_fake.historico_vazio(),
      fila: fila(),
      prompts: portas_fake.prompt_noop(),
      metricas: met(),
      usuarios: portas_fake.usuario_noop(),
      grupos: portas_fake.grupo_noop(),
      transacoes: portas_fake.transacao_noop(),
      providers_config: portas_fake.providers_config_ok(),
    )
  let msg = fixtures.mensagem_comando("curto", "")
  handler_mensagem.handle(msg, portas) |> should.be_ok

  let assert Ok(nova_cfg): Result(config.Config, _) = process.receive(ref, 1000)
  nova_cfg.modo_descricao |> should.equal(config.Curto)
}

pub fn legenda_on_persiste_config_test() {
  let ref = process.new_subject()
  let portas =
    Portas(
      mensageiro: portas_fake.mensageiro_ok(),
      ia_dispatcher: portas_fake.ia_dispatcher_ok("ok"),
      config: portas_fake.config_capturar(ref),
      historico: portas_fake.historico_vazio(),
      fila: fila(),
      prompts: portas_fake.prompt_noop(),
      metricas: met(),
      usuarios: portas_fake.usuario_noop(),
      grupos: portas_fake.grupo_noop(),
      transacoes: portas_fake.transacao_noop(),
      providers_config: portas_fake.providers_config_ok(),
    )
  let msg = fixtures.mensagem_comando("legenda", "on")
  handler_mensagem.handle(msg, portas) |> should.be_ok

  let assert Ok(nova_cfg): Result(config.Config, _) = process.receive(ref, 1000)
  nova_cfg.legenda_ativo |> should.be_true
}

pub fn parear_bloqueado_para_nao_admin_test() {
  use <- env.com_variavel("TELEGRAM_ADMIN_CHAT_ID", "424242")
  let ref_envio = process.new_subject()
  let portas =
    Portas(
      mensageiro: portas_fake.mensageiro_capturar(ref_envio),
      ia_dispatcher: portas_fake.ia_dispatcher_ok("ok"),
      config: portas_fake.config_ok(
        config.Config(..fixtures.config_padrao(), chat_id: "tg:111222"),
      ),
      historico: portas_fake.historico_vazio(),
      fila: fila(),
      prompts: portas_fake.prompt_noop(),
      metricas: met(),
      usuarios: portas_fake.usuario_noop(),
      grupos: portas_fake.grupo_noop(),
      transacoes: portas_fake.transacao_noop(),
      providers_config: portas_fake.providers_config_ok(),
    )
  let msg =
    mensagem.Mensagem(
      ..fixtures.mensagem_comando("parear", ""),
      chat_id: "tg:111222",
      remetente: "tg:111222",
    )
  handler_mensagem.handle(msg, portas) |> should.be_ok

  let assert Ok(#(chat_id, texto)) = process.receive(ref_envio, 1000)
  chat_id |> should.equal("tg:111222")
  string.contains(texto, "restrito ao administrador") |> should.be_true
}

pub fn status_bloqueado_para_nao_admin_test() {
  use <- env.com_variavel("TELEGRAM_ADMIN_CHAT_ID", "424242")
  let ref_envio = process.new_subject()
  let portas =
    Portas(
      mensageiro: portas_fake.mensageiro_capturar(ref_envio),
      ia_dispatcher: portas_fake.ia_dispatcher_ok("ok"),
      config: portas_fake.config_ok(
        config.Config(..fixtures.config_padrao(), chat_id: "tg:111222"),
      ),
      historico: portas_fake.historico_vazio(),
      fila: fila(),
      prompts: portas_fake.prompt_noop(),
      metricas: met(),
      usuarios: portas_fake.usuario_noop(),
      grupos: portas_fake.grupo_noop(),
      transacoes: portas_fake.transacao_noop(),
      providers_config: portas_fake.providers_config_ok(),
    )
  let msg =
    mensagem.Mensagem(
      ..fixtures.mensagem_comando("status", ""),
      chat_id: "tg:111222",
      remetente: "tg:111222",
    )
  handler_mensagem.handle(msg, portas) |> should.be_ok

  let assert Ok(#(chat_id, texto)) = process.receive(ref_envio, 1000)
  chat_id |> should.equal("tg:111222")
  string.contains(texto, "restrito ao administrador") |> should.be_true
}

pub fn status_permitido_para_admin_test() {
  use <- env.com_variavel("TELEGRAM_ADMIN_CHAT_ID", "424242")
  use <- env.com_variavel("WHATSMEOW_URL", "http://127.0.0.1:0")
  let ref_envio = process.new_subject()
  let portas =
    Portas(
      mensageiro: portas_fake.mensageiro_capturar(ref_envio),
      ia_dispatcher: portas_fake.ia_dispatcher_ok("ok"),
      config: portas_fake.config_ok(
        config.Config(..fixtures.config_padrao(), chat_id: "tg:424242"),
      ),
      historico: portas_fake.historico_vazio(),
      fila: fila(),
      prompts: portas_fake.prompt_noop(),
      metricas: met(),
      usuarios: portas_fake.usuario_noop(),
      grupos: portas_fake.grupo_noop(),
      transacoes: portas_fake.transacao_noop(),
      providers_config: portas_fake.providers_config_ok(),
    )
  let msg =
    mensagem.Mensagem(
      ..fixtures.mensagem_comando("status", ""),
      chat_id: "tg:424242",
      remetente: "tg:424242",
    )
  handler_mensagem.handle(msg, portas) |> should.be_ok

  let assert Ok(#(chat_id, texto)) = process.receive(ref_envio, 1000)
  chat_id |> should.equal("tg:424242")
  string.contains(texto, "Painel Administrativo") |> should.be_true
  string.contains(texto, "BEAM") |> should.be_true
}

pub fn reset_whatsapp_bloqueado_para_nao_admin_test() {
  use <- env.com_variavel("TELEGRAM_ADMIN_CHAT_ID", "424242")
  let ref_envio = process.new_subject()
  let portas =
    Portas(
      mensageiro: portas_fake.mensageiro_capturar(ref_envio),
      ia_dispatcher: portas_fake.ia_dispatcher_ok("ok"),
      config: portas_fake.config_ok(
        config.Config(..fixtures.config_padrao(), chat_id: "tg:111222"),
      ),
      historico: portas_fake.historico_vazio(),
      fila: fila(),
      prompts: portas_fake.prompt_noop(),
      metricas: met(),
      usuarios: portas_fake.usuario_noop(),
      grupos: portas_fake.grupo_noop(),
      transacoes: portas_fake.transacao_noop(),
      providers_config: portas_fake.providers_config_ok(),
    )
  let msg =
    mensagem.Mensagem(
      ..fixtures.mensagem_comando("reset_whatsapp", ""),
      chat_id: "tg:111222",
      remetente: "tg:111222",
    )
  handler_mensagem.handle(msg, portas) |> should.be_ok

  let assert Ok(#(chat_id, texto)) = process.receive(ref_envio, 1000)
  chat_id |> should.equal("tg:111222")
  string.contains(texto, "restrito ao administrador") |> should.be_true
}

pub fn reset_whatsapp_permitido_para_admin_test() {
  use <- env.com_variavel("TELEGRAM_ADMIN_CHAT_ID", "424242")
  use <- env.com_variavel("WHATSMEOW_URL", "http://127.0.0.1:0")
  let ref_envio = process.new_subject()
  let portas =
    Portas(
      mensageiro: portas_fake.mensageiro_capturar(ref_envio),
      ia_dispatcher: portas_fake.ia_dispatcher_ok("ok"),
      config: portas_fake.config_ok(
        config.Config(..fixtures.config_padrao(), chat_id: "tg:424242"),
      ),
      historico: portas_fake.historico_vazio(),
      fila: fila(),
      prompts: portas_fake.prompt_noop(),
      metricas: met(),
      usuarios: portas_fake.usuario_noop(),
      grupos: portas_fake.grupo_noop(),
      transacoes: portas_fake.transacao_noop(),
      providers_config: portas_fake.providers_config_ok(),
    )
  let msg =
    mensagem.Mensagem(
      ..fixtures.mensagem_comando("reset_whatsapp", "5531999990000"),
      chat_id: "tg:424242",
      remetente: "tg:424242",
    )
  handler_mensagem.handle(msg, portas) |> should.be_ok

  let assert Ok(#(chat_id, texto)) = process.receive(ref_envio, 1000)
  chat_id |> should.equal("tg:424242")
  // Como o bridge local não está rodando nesta porta nos testes unitários,
  // ou responde que falhou a conexão ou responde iniciado
  {
    string.contains(texto, "Reset do WhatsApp iniciado")
    || string.contains(texto, "Falha ao solicitar reset")
  }
  |> should.be_true
}

pub fn resumo_historico_curto_avisa_usuario_test() {
  let ref_envio = process.new_subject()
  let portas =
    Portas(
      mensageiro: portas_fake.mensageiro_capturar(ref_envio),
      ia_dispatcher: portas_fake.ia_dispatcher_ok("ok"),
      config: portas_fake.config_ok(fixtures.config_padrao()),
      historico: portas_fake.historico_vazio(),
      fila: fila(),
      prompts: portas_fake.prompt_noop(),
      metricas: met(),
      usuarios: portas_fake.usuario_noop(),
      grupos: portas_fake.grupo_noop(),
      transacoes: portas_fake.transacao_noop(),
      providers_config: portas_fake.providers_config_ok(),
    )
  let msg = fixtures.mensagem_comando("resumo", "")
  handler_mensagem.handle(msg, portas) |> should.be_ok

  let assert Ok(#(_chat_id, texto)) = process.receive(ref_envio, 1000)
  string.contains(texto, "Ainda não há mensagens suficientes") |> should.be_true
}

pub fn admin_exige_remetente_chat_privado_e_configuracao_test() {
  verificar_reset_bloqueado("424242", "tg:424242", "tg:111222", False)
  verificar_reset_bloqueado("424242", "tg:111222", "tg:424242", False)
  verificar_reset_bloqueado("424242", "tg:424242", "tg:424242", True)
  verificar_reset_bloqueado("", "tg:924255495", "tg:924255495", False)
}

fn verificar_reset_bloqueado(
  admin: String,
  chat: String,
  remetente: String,
  grupo: Bool,
) {
  use <- env.com_variavel("TELEGRAM_ADMIN_CHAT_ID", admin)
  use <- env.com_variavel("WHATSMEOW_URL", "http://127.0.0.1:0")
  let envios = process.new_subject()
  let cfg = config.Config(..fixtures.config_padrao(), chat_id: chat)
  let portas =
    Portas(
      ..portas_fake.portas_ok(cfg, "unused"),
      mensageiro: portas_fake.mensageiro_capturar(envios),
    )
  let msg =
    mensagem.Mensagem(
      ..fixtures.mensagem_comando("reset_whatsapp", ""),
      chat_id: chat,
      remetente: remetente,
      em_grupo: grupo,
    )
  handler_mensagem.handle(msg, portas) |> should.be_ok
  let assert Ok(#(_, texto)) = process.receive(envios, 1000)
  string.contains(texto, "restrito ao administrador") |> should.be_true
}

pub fn resumo_historico_com_turnos_gera_resumo_test() {
  let ref_envio = process.new_subject()
  let portas =
    Portas(
      mensageiro: portas_fake.mensageiro_capturar(ref_envio),
      ia_dispatcher: portas_fake.ia_dispatcher_ok(
        "Discussão sobre tarefas e decisões.",
      ),
      config: portas_fake.config_ok(fixtures.config_padrao()),
      historico: portas_fake.historico_com(fixtures.historico_com_turnos()),
      fila: fila(),
      prompts: portas_fake.prompt_noop(),
      metricas: met(),
      usuarios: portas_fake.usuario_noop(),
      grupos: portas_fake.grupo_noop(),
      transacoes: portas_fake.transacao_noop(),
      providers_config: portas_fake.providers_config_ok(),
    )
  let msg = fixtures.mensagem_comando("resumo", "")
  handler_mensagem.handle(msg, portas) |> should.be_ok

  let assert Ok(#(_chat_id, texto)) = process.receive(ref_envio, 1000)
  string.contains(texto, "Resumo da conversa:") |> should.be_true
  string.contains(texto, "Discussão sobre tarefas e decisões.")
  |> should.be_true
}
