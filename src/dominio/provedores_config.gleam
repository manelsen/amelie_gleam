// Configuração de provedores e modelos disponíveis, lida de providers.yaml.
// As chaves do YAML (`providers:`, `name:`) seguem o formato do arquivo.

import dominio/erro.{type Erro}
import dominio/provedor
import gleam/dict
import gleam/list
import gleam/option
import gleam/result
import gleam/string

/// Um provedor como aparece no YAML: nome de exibição e modelos aceitos.
pub type ProvedorConfigurado {
  ProvedorConfigurado(nome: String, modelos: List(String))
}

pub type ProvedoresConfig {
  ProvedoresConfig(provedores: dict.Dict(String, ProvedorConfigurado))
}

type EstadoLeitura {
  EstadoLeitura(
    provedores: dict.Dict(String, ProvedorConfigurado),
    chave_atual: option.Option(String),
    nome_atual: option.Option(String),
    modelos_atuais: List(String),
  )
}

pub fn padrao() -> ProvedoresConfig {
  ProvedoresConfig(
    provedores: dict.from_list([
      #(
        "gemini",
        ProvedorConfigurado(nome: "Google Gemini", modelos: [
          "gemini-3.5-flash-lite",
          "gemini-3.8-flash",
          "gemini-3.1-flash-lite",
          "gemini-2.5-flash-lite",
          "gemini-2.5-pro",
          "gemini-1.5-flash",
          "gemini-1.5-pro",
        ]),
      ),
      #(
        "openrouter",
        ProvedorConfigurado(nome: "OpenRouter", modelos: [
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

pub fn validar_modelo(
  config: ProvedoresConfig,
  nome_provedor: String,
  modelo: String,
) -> Result(provedor.Provedor, Erro) {
  case dict.get(config.provedores, nome_provedor) {
    Ok(configurado) -> {
      case list.contains(configurado.modelos, modelo) {
        True ->
          provedor.de_string(nome_provedor)
          |> result.replace_error(erro.ErroComunicacao(
            "provedor '" <> nome_provedor <> "' não tem adaptador implementado",
          ))
        False ->
          Error(erro.ErroComunicacao(
            "modelo '"
            <> modelo
            <> "' não disponível para provedor '"
            <> nome_provedor
            <> "'. Modelos disponíveis: "
            <> string.join(configurado.modelos, ", "),
          ))
      }
    }
    Error(_) ->
      Error(erro.ErroComunicacao(
        "provedor '" <> nome_provedor <> "' não encontrado",
      ))
  }
}

pub fn listar_provedores(config: ProvedoresConfig) -> List(String) {
  dict.keys(config.provedores)
}

/// Lê o conteúdo de providers.yaml. Quem chama é responsável por ler o arquivo.
pub fn parsear(texto: String) -> Result(ProvedoresConfig, Erro) {
  let inicial =
    EstadoLeitura(
      provedores: dict.new(),
      chave_atual: option.None,
      nome_atual: option.None,
      modelos_atuais: [],
    )

  let final =
    texto
    |> string.split("\n")
    |> list.fold(inicial, parsear_linha)
    |> fechar_provedor

  case dict.size(final.provedores) > 0 {
    True -> Ok(ProvedoresConfig(provedores: final.provedores))
    False -> Error(erro.ErroComunicacao("nenhum provider encontrado no yaml"))
  }
}

fn parsear_linha(estado: EstadoLeitura, linha: String) -> EstadoLeitura {
  let aparada = string.trim(linha)

  case aparada == "" || string.starts_with(aparada, "#") {
    True -> estado
    False ->
      case aparada {
        "providers:" -> estado
        _ ->
          case e_linha_de_provedor(linha, aparada) {
            True -> {
              let estado = fechar_provedor(estado)
              EstadoLeitura(
                ..estado,
                chave_atual: option.Some(remover_sufixo(aparada, ":")),
                nome_atual: option.None,
                modelos_atuais: [],
              )
            }
            False ->
              case string.starts_with(linha, "    name:") {
                True ->
                  EstadoLeitura(
                    ..estado,
                    nome_atual: option.Some(extrair_valor_yaml(
                      linha,
                      "    name:",
                    )),
                  )
                False ->
                  case string.starts_with(linha, "      - ") {
                    True ->
                      EstadoLeitura(..estado, modelos_atuais: [
                        extrair_valor_yaml(linha, "      - "),
                        ..estado.modelos_atuais
                      ])
                    False -> estado
                  }
              }
          }
      }
  }
}

fn e_linha_de_provedor(linha: String, aparada: String) -> Bool {
  string.starts_with(linha, "  ")
  && !string.starts_with(linha, "    ")
  && string.ends_with(aparada, ":")
}

/// Fecha o provedor que estava sendo lido e o guarda no dicionário.
fn fechar_provedor(estado: EstadoLeitura) -> EstadoLeitura {
  case estado.chave_atual {
    option.None -> estado
    option.Some(chave) -> {
      let configurado =
        ProvedorConfigurado(
          nome: option.unwrap(estado.nome_atual, chave),
          modelos: list.reverse(estado.modelos_atuais),
        )
      EstadoLeitura(
        provedores: dict.insert(estado.provedores, chave, configurado),
        chave_atual: option.None,
        nome_atual: option.None,
        modelos_atuais: [],
      )
    }
  }
}

fn extrair_valor_yaml(linha: String, prefixo: String) -> String {
  linha
  |> string.trim
  |> string.drop_start(string.length(string.trim(prefixo)))
  |> string.trim
  |> remover_aspas
}

fn remover_aspas(valor: String) -> String {
  let aparado = string.trim(valor)
  case string.starts_with(aparado, "\"") && string.ends_with(aparado, "\"") {
    True -> aparado |> string.drop_start(1) |> string.drop_end(1)
    False -> aparado
  }
}

fn remover_sufixo(valor: String, sufixo: String) -> String {
  case string.ends_with(valor, sufixo) {
    True -> string.drop_end(valor, string.length(sufixo))
    False -> valor
  }
}
