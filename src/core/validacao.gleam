// Funções puras de validação. Sem efeitos.

import dominio/erro.{type Erro}
import dominio/id_chat
import dominio/mensagem.{type Mensagem}
import gleam/list
import gleam/string

pub fn validar_texto(body: String) -> Result(String, Erro) {
  let trimmed = string.trim(body)
  case string.length(trimmed) {
    0 -> Error(erro.ErroValidacao("body", "texto vazio"))
    _ -> Ok(trimmed)
  }
}

const comandos_conhecidos = [
  "ajuda", "start", "reset", "audio", "imagem", "video", "doc", "legenda",
  "longo", "curto", "cego", "modelo", "parear", "status", "reset_whatsapp",
  "resumo", "snapshot", "compactar", "unban", "desbloquear", "spammers",
  "bloqueados",
]

pub fn parsear_comando(body: String) -> Result(#(String, String), Erro) {
  case string.trim(body) {
    "." <> rest | "/" <> rest -> {
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

pub fn parsear_comando_sem_ponto(
  body: String,
) -> Result(#(String, String), Erro) {
  let #(primeira, resto) = case string.split_once(body, " ") {
    Ok(#(p, r)) -> #(p, string.trim(r))
    Error(_) -> #(body, "")
  }
  let nome = normalizar_nome_comando(primeira)
  case
    list.contains(comandos_conhecidos, nome)
    && argumento_sem_ponto_valido(nome, resto)
  {
    True -> Ok(#(nome, resto))
    False -> Error(erro.ErroValidacao("body", "não é um comando"))
  }
}

/// Sem ponto, só a mensagem inteira vira comando: o nome sozinho ou o nome
/// com um argumento que ele aceita. "Reset minha conversa" ou "imagem bonita"
/// são frases para a IA, não comandos.
fn argumento_sem_ponto_valido(nome: String, args: String) -> Bool {
  let um_token = args != "" && !string.contains(args, " ")
  case nome, string.lowercase(args) {
    _, "" -> True
    "audio", "on" | "audio", "off" -> True
    "imagem", "on" | "imagem", "off" -> True
    "video", "on" | "video", "off" -> True
    "doc", "on" | "doc", "off" -> True
    "modelo", a -> um_token && string.contains(a, "/")
    "parear", a | "reset_whatsapp", a -> e_telefone(a)
    "unban", a | "desbloquear", a -> um_token || e_telefone(a)
    _, _ -> False
  }
}

/// Telefone como as pessoas digitam: "55 31 99999-0000", "+55 (31) 99999-0000".
fn e_telefone(args: String) -> Bool {
  let caracteres = string.to_graphemes(args)
  list.any(caracteres, e_digito)
  && list.all(caracteres, fn(c) {
    e_digito(c) || list.contains([" ", "+", "-", "(", ")"], c)
  })
}

fn e_digito(c: String) -> Bool {
  list.contains(["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"], c)
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
  string.ends_with(id_chat.para_texto(msg.remetente), ":bot")
}
