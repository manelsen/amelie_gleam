import dominio/config
import dominio/provedor
import dominio/providers_config
import gleam/dict
import gleam/list
import gleeunit/should
import simplifile

fn ler_yaml() -> providers_config.ProvidersConfig {
  let assert Ok(texto) = simplifile.read("./config/providers.yaml")
  let assert Ok(cfg) = providers_config.parsear(texto)
  cfg
}

pub fn ler_arquivo_yaml_test() {
  let cfg = ler_yaml()
  let providers = providers_config.listar_provedores(cfg)
  list.contains(providers, "gemini") |> should.be_true
  list.contains(providers, "openrouter") |> should.be_true
}

pub fn validar_modelo_yaml_test() {
  let cfg = ler_yaml()
  providers_config.validar_modelo(cfg, "gemini", "gemini-3.5-flash-lite")
  |> should.be_ok
}

pub fn modelo_padrao_e_gemini_3_5_flash_lite_test() {
  let cfg = config.padrao("chat")
  cfg.modelo |> should.equal("gemini-3.5-flash-lite")
}

pub fn validar_modelo_devolve_o_provedor_test() {
  let cfg = providers_config.padrao()
  providers_config.validar_modelo(cfg, "openrouter", "openai/gpt-4o")
  |> should.equal(Ok(provedor.OpenRouter))
  providers_config.validar_modelo(cfg, "gemini", "gemini-2.5-pro")
  |> should.equal(Ok(provedor.Gemini))
}

pub fn validar_modelo_recusa_provedor_sem_adaptador_test() {
  // Um provedor listado no YAML, mas sem adaptador, antes caía no Gemini
  // sem aviso.
  let cfg =
    providers_config.ProvidersConfig(
      providers: dict.from_list([
        #(
          "anthropic",
          providers_config.Provedor(name: "Anthropic", models: ["claude"]),
        ),
      ]),
    )
  providers_config.validar_modelo(cfg, "anthropic", "claude")
  |> should.be_error
}

pub fn nomes_de_provedor_vao_e_voltam_test() {
  [provedor.Gemini, provedor.OpenRouter]
  |> list.each(fn(p) {
    provedor.de_string(provedor.para_string(p)) |> should.equal(Ok(p))
  })
  provedor.de_string("anthropic") |> should.equal(Error(Nil))
}
