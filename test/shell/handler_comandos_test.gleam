// Testes de integração do shell para comandos.
// Verificam que o handler executa corretamente SalvarConfig e LimparHistorico.

import dominio/config
import dominio/erro
import gleam/erlang/process
import gleam/option
import gleeunit/should
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
      whatsapp: portas_fake.whatsapp_ok(),
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
      whatsapp: portas_fake.whatsapp_ok(),
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

pub fn reset_limpa_historico_test() {
  let ref = process.new_subject()
  let portas =
    Portas(
      whatsapp: portas_fake.whatsapp_ok(),
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
      whatsapp: portas_fake.whatsapp_ok(),
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
  nova_cfg.audio_ativo |> should.be_false
}

// Testes para novos comandos

pub fn longo_persiste_config_test() {
  let ref = process.new_subject()
  let portas =
    Portas(
      whatsapp: portas_fake.whatsapp_ok(),
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
      whatsapp: portas_fake.whatsapp_ok(),
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
      whatsapp: portas_fake.whatsapp_ok(),
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
