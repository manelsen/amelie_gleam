import adaptadores/config_sqlite
import dominio/config
import dominio/provedor
import gleeunit/should
import sqlight

pub fn migrar_antigo_modelo_padrao_para_gemini_3_5_flash_lite_test() {
  use conn <- sqlight.with_connection("file:config_model_migration?mode=memory")
  let porta = config_sqlite.criar(conn)
  let antiga =
    config.Config(..config.padrao("chat-antigo"), modelo: "gemini-3.8-flash")
  let assert Ok(Nil) = porta.salvar(antiga)

  let porta_migrada = config_sqlite.criar(conn)
  let assert Ok(atual) = porta_migrada.obter("chat-antigo")

  atual.modelo |> should.equal("gemini-3.5-flash-lite")
}

pub fn migracao_preserva_modelo_escolhido_test() {
  use conn <- sqlight.with_connection("file:config_custom_model?mode=memory")
  let porta = config_sqlite.criar(conn)
  let escolhida =
    config.Config(..config.padrao("chat-customizado"), modelo: "gemini-2.5-pro")
  let assert Ok(Nil) = porta.salvar(escolhida)

  let porta_migrada = config_sqlite.criar(conn)
  let assert Ok(atual) = porta_migrada.obter("chat-customizado")

  atual.modelo |> should.equal("gemini-2.5-pro")
}

pub fn provedor_openrouter_persiste_test() {
  use conn <- sqlight.with_connection("file:config_provedor?mode=memory")
  let porta = config_sqlite.criar(conn)
  let cfg =
    config.Config(
      ..config.padrao("chat-or"),
      provedor: provedor.OpenRouter,
      modelo: "openai/gpt-4o",
    )
  let assert Ok(Nil) = porta.salvar(cfg)

  let assert Ok(lida) = porta.obter("chat-or")
  lida.provedor |> should.equal(provedor.OpenRouter)
}

pub fn provedor_desconhecido_no_banco_vira_gemini_test() {
  use conn <- sqlight.with_connection("file:config_provedor_antigo?mode=memory")
  let porta = config_sqlite.criar(conn)
  let assert Ok(Nil) = porta.salvar(config.padrao("chat-x"))
  let assert Ok(Nil) =
    sqlight.exec(
      "UPDATE configs SET provedor = 'anthropic' WHERE chat_id = 'chat-x'",
      conn,
    )

  let assert Ok(lida) = porta.obter("chat-x")
  lida.provedor |> should.equal(provedor.Gemini)
}
