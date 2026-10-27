// Identificador de conversa ou de usuário, nos dois canais. Opaco: só nasce
// pelos construtores daqui, então o formato textual (`tg:<número>` para o
// Telegram, JID para o WhatsApp) é decifrado num lugar só. O texto aparece
// apenas nas bordas: SQLite, JSON da ponte e da Bot API, logs.

import gleam/bool
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/result
import gleam/string

pub opaque type IdChat {
  Telegram(numero: Int)
  Whatsapp(jid: String)
}

pub type Canal {
  CanalTelegram
  CanalWhatsapp
}

const prefixo_telegram = "tg:"

pub fn telegram(numero: Int) -> IdChat {
  Telegram(numero)
}

/// JID do WhatsApp (`usuario@servidor`, com ou sem agente/dispositivo).
/// Recusa texto sem servidor e texto que imite um ID do Telegram.
pub fn whatsapp(jid: String) -> Result(IdChat, Nil) {
  use <- bool.guard(string.starts_with(jid, prefixo_telegram), Error(Nil))
  case string.split_once(jid, "@") {
    Ok(#(usuario, servidor)) if usuario != "" && servidor != "" ->
      Ok(Whatsapp(jid))
    _ -> Error(Nil)
  }
}

/// Lê a forma textual produzida por `para_texto`.
pub fn de_texto(texto: String) -> Result(IdChat, Nil) {
  case texto {
    "tg:" <> numero -> int.parse(numero) |> result.map(Telegram)
    _ -> whatsapp(texto)
  }
}

pub fn para_texto(id: IdChat) -> String {
  case id {
    Telegram(numero) -> prefixo_telegram <> int.to_string(numero)
    Whatsapp(jid) -> jid
  }
}

pub fn canal(id: IdChat) -> Canal {
  case id {
    Telegram(_) -> CanalTelegram
    Whatsapp(_) -> CanalWhatsapp
  }
}

/// Número do chat na Bot API; erro para IDs do WhatsApp.
pub fn numero_telegram(id: IdChat) -> Result(Int, Nil) {
  case id {
    Telegram(numero) -> Ok(numero)
    Whatsapp(_) -> Error(Nil)
  }
}

/// Se o texto digitado (por exemplo, pelo admin no `.unban`) aponta para
/// este ID: a forma textual completa ou só o número, com ou sem pontuação.
pub fn corresponde(id: IdChat, texto: String) -> Bool {
  let texto = string.trim(texto)
  let digitos = so_digitos(texto)
  texto == para_texto(id)
  || { digitos != "" && digitos == so_digitos(numero(id)) }
}

/// Número do usuário: o do Telegram ou a parte do JID antes do agente,
/// do dispositivo e do servidor.
fn numero(id: IdChat) -> String {
  case id {
    Telegram(numero) -> int.to_string(numero)
    Whatsapp(jid) -> {
      let usuario = case string.split_once(jid, "@") {
        Ok(#(usuario, _)) -> usuario
        Error(Nil) -> jid
      }
      case string.split_once(usuario, ":") {
        Ok(#(usuario, _)) -> usuario
        Error(Nil) -> usuario
      }
    }
  }
}

fn so_digitos(texto: String) -> String {
  texto
  |> string.to_graphemes
  |> list.filter(fn(g) { string.contains("0123456789", g) })
  |> string.concat
}

/// Decodifica a forma textual vinda do SQLite ou de JSON.
pub fn decoder() -> decode.Decoder(IdChat) {
  use texto <- decode.then(decode.string)
  case de_texto(texto) {
    Ok(id) -> decode.success(id)
    Error(Nil) -> decode.failure(Telegram(0), "IdChat")
  }
}
