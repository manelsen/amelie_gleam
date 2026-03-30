// Funções puras de validação. Sem efeitos.

import dominio/erro.{type Erro}
import dominio/mensagem.{type Mensagem}
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

pub fn parsear_comando(body: String) -> Result(#(String, String), Erro) {
  case string.trim(body) {
    "." <> rest -> {
      let partes = string.split_once(rest, " ")
      case partes {
        Ok(#(nome, args)) -> Ok(#(string.lowercase(nome), string.trim(args)))
        Error(_) -> Ok(#(string.lowercase(rest), ""))
      }
    }
    _ -> Error(erro.ErroValidacao("body", "não é um comando"))
  }
}

pub fn e_mensagem_propria(msg: Mensagem) -> Bool {
  string.ends_with(msg.remetente, ":bot")
}
