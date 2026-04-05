// Funções puras de validação. Sem efeitos.

import dominio/erro.{type Erro}
import dominio/mensagem.{type Mensagem}
import gleam/list
import gleam/string

pub fn validar_mensagem(msg: Mensagem) -> Result(Mensagem, Erro) {
  case msg.chat_id {
    "" -> Error(erro.ErroValidacao("chat_id", "vazio"))
    _ ->
      case msg.remetente {
        "" -> Error(erro.ErroValidacao("remetente", "vazio"))
        _ -> Ok(msg)
      }
  }
}

pub fn validar_texto(body: String) -> Result(String, Erro) {
  let trimmed = string.trim(body)
  case string.length(trimmed) {
    0 -> Error(erro.ErroValidacao("body", "texto vazio"))
    l if l > 4096 ->
      Error(erro.ErroValidacao("body", "texto excede 4096 caracteres"))
    _ -> Ok(trimmed)
  }
}

const comandos_conhecidos = [
  "ajuda", "reset", "audio", "imagem", "video", "doc", "legenda", "longo",
  "curto", "cego", "modelo",
]

pub fn parsear_comando(body: String) -> Result(#(String, String), Erro) {
  case string.trim(body) {
    "." <> rest -> {
      let rest = string.trim(rest)
      case string.split_once(rest, " ") {
        Ok(#(nome, args)) ->
          Ok(#(normalizar_nome_comando(nome), string.trim(args)))
        Error(_) -> Ok(#(normalizar_nome_comando(rest), ""))
      }
    }
    trimmed -> parsear_comando_sem_ponto(trimmed)
  }
}

pub fn parsear_comando_sem_ponto(body: String) -> Result(#(String, String), Erro) {
  let #(primeira, resto) = case string.split_once(body, " ") {
    Ok(#(p, r)) -> #(p, string.trim(r))
    Error(_) -> #(body, "")
  }
  let nome = normalizar_nome_comando(primeira)
  case list.contains(comandos_conhecidos, nome) {
    True -> Ok(#(nome, resto))
    False -> Error(erro.ErroValidacao("body", "não é um comando"))
  }
}

pub fn normalizar_nome_comando(nome: String) -> String {
  nome
  |> string.trim()
  |> string.lowercase()
  |> remover_acentos()
}

fn remover_acentos(texto: String) -> String {
  texto
  |> string.replace("á", "a")
  |> string.replace("à", "a")
  |> string.replace("ã", "a")
  |> string.replace("â", "a")
  |> string.replace("é", "e")
  |> string.replace("ê", "e")
  |> string.replace("í", "i")
  |> string.replace("ó", "o")
  |> string.replace("ô", "o")
  |> string.replace("õ", "o")
  |> string.replace("ú", "u")
  |> string.replace("ü", "u")
  |> string.replace("ç", "c")
}

pub fn e_mensagem_propria(msg: Mensagem) -> Bool {
  string.ends_with(msg.remetente, ":bot")
}
