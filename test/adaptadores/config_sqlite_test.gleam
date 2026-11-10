import adaptadores/config_sqlite
import dominio/config
import dominio/provedor
import gleam/option
import gleeunit/should
import helpers/fixtures
import sqlight

pub fn migrar_antigo_modelo_padrao_para_gemini_3_5_flash_lite_test() {
  use conn <- sqlight.with_connection("file:config_model_migration?mode=memory")
  let porta = config_sqlite.criar(conn)
  let antiga =
    config.Config(
      ..config.padrao(fixtures.id("chat-antigo@c.us")),
      modelo: "gemini-3.8-flash",
    )
  let assert Ok(Nil) = porta.salvar(antiga)
  // Banco de antes do registro de migrações: a migração ainda não rodou.
  let assert Ok(Nil) = sqlight.exec("DELETE FROM migracoes", conn)

  let porta_migrada = config_sqlite.criar(conn)
  let assert Ok(atual) = porta_migrada.obter(fixtures.id("chat-antigo@c.us"))

  atual.modelo |> should.equal("gemini-3.5-flash-lite")
}

pub fn migracao_preserva_modelo_escolhido_test() {
  use conn <- sqlight.with_connection("file:config_custom_model?mode=memory")
  let porta = config_sqlite.criar(conn)
  let escolhida =
    config.Config(
      ..config.padrao(fixtures.id("chat-customizado@c.us")),
      modelo: "gemini-2.5-pro",
    )
  let assert Ok(Nil) = porta.salvar(escolhida)

  let porta_migrada = config_sqlite.criar(conn)
  let assert Ok(atual) =
    porta_migrada.obter(fixtures.id("chat-customizado@c.us"))

  atual.modelo |> should.equal("gemini-2.5-pro")
}

pub fn provedor_openrouter_persiste_test() {
  use conn <- sqlight.with_connection("file:config_provedor?mode=memory")
  let porta = config_sqlite.criar(conn)
  let cfg =
    config.Config(
      ..config.padrao(fixtures.id("chat-or@c.us")),
      provedor: provedor.OpenRouter,
      modelo: "openai/gpt-4o",
    )
  let assert Ok(Nil) = porta.salvar(cfg)

  let assert Ok(lida) = porta.obter(fixtures.id("chat-or@c.us"))
  lida.provedor |> should.equal(provedor.OpenRouter)
}

pub fn provedor_desconhecido_no_banco_vira_gemini_test() {
  use conn <- sqlight.with_connection("file:config_provedor_antigo?mode=memory")
  let porta = config_sqlite.criar(conn)
  let assert Ok(Nil) = porta.salvar(config.padrao(fixtures.id("chat-x@c.us")))
  let assert Ok(Nil) =
    sqlight.exec(
      "UPDATE configs SET provedor = 'anthropic' WHERE chat_id = 'chat-x'",
      conn,
    )

  let assert Ok(lida) = porta.obter(fixtures.id("chat-x@c.us"))
  lida.provedor |> should.equal(provedor.Gemini)
}

pub fn reinicio_preserva_prompt_e_video_desligado_test() {
  use conn <- sqlight.with_connection("file:config_reinicio?mode=memory")
  let porta = config_sqlite.criar(conn)
  let cfg =
    config.Config(
      ..config.padrao(fixtures.id("chat-prefs@c.us")),
      prompt_sistema: option.Some("Responda como pirata."),
      video_ativo: False,
      audio_ativo: False,
    )
  let assert Ok(Nil) = porta.salvar(cfg)

  let porta_reiniciada = config_sqlite.criar(conn)
  let assert Ok(lida) = porta_reiniciada.obter(fixtures.id("chat-prefs@c.us"))

  lida.prompt_sistema |> should.equal(option.Some("Responda como pirata."))
  lida.video_ativo |> should.be_false
  lida.audio_ativo |> should.be_false
}

pub fn modelo_escolhido_depois_da_migracao_sobrevive_ao_reinicio_test() {
  use conn <- sqlight.with_connection("file:config_migracao_unica?mode=memory")
  let porta = config_sqlite.criar(conn)
  // Troca feita pelo admin com `.modelo`.
  let escolhida =
    config.Config(
      ..config.padrao(fixtures.id("chat-escolheu@c.us")),
      modelo: "gemini-3.8-flash",
    )
  let assert Ok(Nil) = porta.salvar(escolhida)

  let porta_reiniciada = config_sqlite.criar(conn)
  let assert Ok(atual) =
    porta_reiniciada.obter(fixtures.id("chat-escolheu@c.us"))

  atual.modelo |> should.equal("gemini-3.8-flash")
}
