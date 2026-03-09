import gleam/list
import dominio/providers_config
import gleeunit/should

pub fn ler_arquivo_yaml_test() {
  let assert Ok(cfg) = providers_config.ler_arquivo("./config/providers.yaml")
  let providers = providers_config.listar_provedores(cfg)
  list.contains(providers, "gemini") |> should.be_true
  list.contains(providers, "openrouter") |> should.be_true
}

pub fn validar_modelo_yaml_test() {
  let assert Ok(cfg) = providers_config.ler_arquivo("./config/providers.yaml")
  providers_config.validar_modelo(cfg, "gemini", "gemini-2.5-flash-lite")
  |> should.be_ok
}
