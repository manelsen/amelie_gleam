import adaptadores/config_sqlite
import dominio/config
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
