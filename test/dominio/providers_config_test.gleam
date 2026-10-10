import dominio/config
import dominio/providers_config
import gleam/list
import gleeunit/should

pub fn ler_arquivo_yaml_test() {
  let assert Ok(cfg) = providers_config.ler_arquivo("./config/providers.yaml")
  let providers = providers_config.listar_provedores(cfg)
  list.contains(providers, "gemini") |> should.be_true
  list.contains(providers, "openrouter") |> should.be_true
}

pub fn validar_modelo_yaml_test() {
  let assert Ok(cfg) = providers_config.ler_arquivo("./config/providers.yaml")
  providers_config.validar_modelo(cfg, "gemini", "gemini-3.5-flash-lite")
  |> should.be_ok
}

pub fn modelo_padrao_e_gemini_3_5_flash_lite_test() {
  let cfg = config.padrao("chat")
  cfg.modelo |> should.equal("gemini-3.5-flash-lite")
}
