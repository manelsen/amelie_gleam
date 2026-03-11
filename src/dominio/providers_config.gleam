// Configuração de provedores e modelos disponíveis.

import dominio/erro.{type Erro}
import gleam/bit_array
import gleam/dict
import gleam/list
import gleam/option
import gleam/result
import gleam/string

pub type Provedor {
  Provedor(name: String, models: List(String))
}

pub type ProvidersConfig {
  ProvidersConfig(providers: dict.Dict(String, Provedor))
}

pub type ModeloConfig {
  ModeloConfig(provider: String, model: String)
}

type ParseState {
  ParseState(
    providers: dict.Dict(String, Provedor),
    current_provider: option.Option(String),
    current_name: option.Option(String),
    current_models: List(String),
  )
}

pub fn padrao() -> ProvidersConfig {
  ProvidersConfig(
    providers: dict.from_list([
      #(
        "gemini",
        Provedor(name: "Google Gemini", models: [
          "gemini-2.5-flash-lite",
          "gemini-2.5-pro",
          "gemini-1.5-flash",
          "gemini-1.5-pro",
        ]),
      ),
      #(
        "openrouter",
        Provedor(name: "OpenRouter", models: [
          "anthropic/claude-3.5-sonnet",
          "anthropic/claude-3.5-haiku",
          "openai/gpt-4o",
          "openai/gpt-4o-mini",
          "google/gemini-pro-1.5",
          "meta-llama/llama-3.1-405b-instruct",
        ]),
      ),
    ]),
  )
}

@external(erlang, "amelie_gleam_ffi", "read_file")
fn read_file(path: String) -> Result(BitArray, String)

pub fn ler_arquivo(caminho: String) -> Result(ProvidersConfig, Erro) {
  use contents <- result.try(
    read_file(caminho)
    |> result.map_error(fn(e) {
      erro.ErroComunicacao("erro ao ler providers yaml: " <> e)
    }),
  )
  use text <- result.try(
    bit_array.to_string(contents)
    |> result.map_error(fn(_) {
      erro.ErroComunicacao("providers yaml inválido")
    }),
  )
  parsear_yaml(text)
}

pub fn validar_modelo(
  config: ProvidersConfig,
  provider: String,
  model: String,
) -> Result(Nil, Erro) {
  case dict.get(config.providers, provider) {
    Ok(prov) -> {
      case list.contains(prov.models, model) {
        True -> Ok(Nil)
        False ->
          Error(erro.ErroComunicacao(
            "modelo '"
            <> model
            <> "' não disponível para provedor '"
            <> provider
            <> "'. Modelos disponíveis: "
            <> string.join(prov.models, ", "),
          ))
      }
    }
    Error(_) ->
      Error(erro.ErroComunicacao("provedor '" <> provider <> "' não encontrado"))
  }
}

pub fn listar_modelos(
  config: ProvidersConfig,
  provider: String,
) -> Result(List(String), Erro) {
  case dict.get(config.providers, provider) {
    Ok(prov) -> Ok(prov.models)
    Error(_) ->
      Error(erro.ErroComunicacao("provedor '" <> provider <> "' não encontrado"))
  }
}

pub fn listar_provedores(config: ProvidersConfig) -> List(String) {
  dict.keys(config.providers)
}

pub fn formatar_provedores(config: ProvidersConfig) -> String {
  let providers = dict.to_list(config.providers)
  list.fold(providers, "*Provedores disponíveis:*\n\n", fn(acc, pair) {
    let #(key, prov) = pair
    acc <> "- **" <> key <> "** (" <> prov.name <> ")\n"
  })
}

pub fn formatar_modelos(
  config: ProvidersConfig,
  provider: String,
) -> Result(String, Erro) {
  use models <- result.try(listar_modelos(config, provider))
  Ok(
    "*Modelos disponíveis para `"
    <> provider
    <> "`:*\n\n"
    <> string.join(list.map(models, fn(m) { "- `" <> m <> "`" }), "\n"),
  )
}

pub fn parsear_modelo_str(s: String) -> Result(ModeloConfig, Erro) {
  case string.split_once(s, "/") {
    Ok(#(provider, model)) ->
      Ok(ModeloConfig(
        provider: string.trim(provider),
        model: string.trim(model),
      ))
    Error(_) ->
      Error(erro.ErroComunicacao(
        "formato inválido: esperado 'provedor/modelo', recebido '" <> s <> "'",
      ))
  }
}

fn parsear_yaml(text: String) -> Result(ProvidersConfig, Erro) {
  let initial =
    ParseState(
      providers: dict.new(),
      current_provider: option.None,
      current_name: option.None,
      current_models: [],
    )

  let final_state =
    text
    |> string.split("\n")
    |> list.fold(initial, fn(state, line) { parsear_linha(state, line) })
    |> flush_provider

  case dict.size(final_state.providers) > 0 {
    True -> Ok(ProvidersConfig(providers: final_state.providers))
    False -> Error(erro.ErroComunicacao("nenhum provider encontrado no yaml"))
  }
}

fn parsear_linha(state: ParseState, line: String) -> ParseState {
  let trimmed = string.trim(line)

  case trimmed == "" || string.starts_with(trimmed, "#") {
    True -> state
    False ->
      case trimmed {
        "providers:" -> state
        _ ->
          case is_provider_line(line, trimmed) {
            True -> {
              let state = flush_provider(state)
              ParseState(
                ..state,
                current_provider: option.Some(remove_suffix(trimmed, ":")),
                current_name: option.None,
                current_models: [],
              )
            }
            False ->
              case string.starts_with(line, "    name:") {
                True ->
                  ParseState(
                    ..state,
                    current_name: option.Some(extract_yaml_value(line, "    name:")),
                  )
                False ->
                  case string.starts_with(line, "      - ") {
                    True ->
                      ParseState(
                        ..state,
                        current_models: [
                          extract_yaml_value(line, "      - "),
                          ..state.current_models
                        ],
                      )
                    False -> state
                  }
              }
          }
      }
  }
}

fn is_provider_line(line: String, trimmed: String) -> Bool {
  string.starts_with(line, "  ")
  && !string.starts_with(line, "    ")
  && string.ends_with(trimmed, ":")
}

fn flush_provider(state: ParseState) -> ParseState {
  case state.current_provider {
    option.None -> state
    option.Some(provider_key) -> {
      let name = option.unwrap(state.current_name, provider_key)
      let provider =
        Provedor(name: name, models: list.reverse(state.current_models))
      ParseState(
        providers: dict.insert(state.providers, provider_key, provider),
        current_provider: option.None,
        current_name: option.None,
        current_models: [],
      )
    }
  }
}

fn extract_yaml_value(line: String, prefix: String) -> String {
  line
  |> string.trim
  |> string.drop_start(string.length(string.trim(prefix)))
  |> string.trim
  |> remove_wrapping_quotes
}

fn remove_wrapping_quotes(value: String) -> String {
  let trimmed = string.trim(value)
  case string.starts_with(trimmed, "\"") && string.ends_with(trimmed, "\"") {
    True -> trimmed |> string.drop_start(1) |> string.drop_end(1)
    False -> trimmed
  }
}

fn remove_suffix(value: String, suffix: String) -> String {
  case string.ends_with(value, suffix) {
    True -> string.drop_end(value, string.length(suffix))
    False -> value
  }
}
