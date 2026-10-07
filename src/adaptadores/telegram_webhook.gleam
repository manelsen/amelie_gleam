// Decodificador de Webhook da Telegram Bot API.
// Converte updates do Telegram para o tipo de domínio Mensagem.
// Rejeita categoricamente qualquer mensagem de grupo.

import dominio/erro.{type Erro}
import dominio/mensagem.{type Mensagem, Mensagem}
import gleam/bit_array
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub type TelegramUpdate {
  TelegramUpdate(update_id: Int, message: Option(TelegramMessage))
}

pub type TelegramMessage {
  TelegramMessage(
    message_id: Int,
    date: Int,
    chat_id: Int,
    chat_type: String,
    from_id: Option(Int),
    text: Option(String),
  )
}

pub type UpdateItem {
  UpdateItem(update_id: Int, mensagem: Option(Mensagem))
}

pub fn parsear_update(body: BitArray) -> Result(Option(Mensagem), Erro) {
  use s <- result.try(
    bit_array.to_string(body)
    |> result.map_error(fn(_) {
      erro.ErroValidacao("telegram", "corpo inválido (não-utf8)")
    }),
  )
  use update <- result.try(
    json.parse(s, telegram_update_decoder())
    |> result.map_error(fn(_) {
      erro.ErroValidacao("telegram", "json de update inválido")
    }),
  )

  case update.message {
    None -> Ok(None)
    Some(msg) -> Ok(converter_mensagem(msg))
  }
}

pub fn extrair_updates(json_str: String) -> Result(List(UpdateItem), Erro) {
  use updates <- result.try(
    json.parse(json_str, get_updates_response_decoder())
    |> result.map_error(fn(_) {
      erro.ErroValidacao("telegram", "json de getUpdates inválido")
    }),
  )

  let itens =
    list.map(updates, fn(up) {
      let msg_opt = case up.message {
        None -> None
        Some(m) -> converter_mensagem(m)
      }
      UpdateItem(update_id: up.update_id, mensagem: msg_opt)
    })
  Ok(itens)
}

pub fn converter_mensagem(msg: TelegramMessage) -> Option(Mensagem) {
  case msg.chat_type == "private" {
    False -> None
    True -> {
      case msg.text {
        None -> None
        Some(raw_text) -> {
          let sender_id = option.unwrap(msg.from_id, msg.chat_id)
          let corpo = parsear_texto_ou_comando(raw_text)
          Some(Mensagem(
            chat_id: "tg:" <> int.to_string(msg.chat_id),
            remetente: "tg:" <> int.to_string(sender_id),
            message_id: Some(int.to_string(msg.message_id)),
            corpo: corpo,
            timestamp: msg.date,
            em_grupo: False,
            nome_grupo: None,
            menciona_bot: True,
            legenda: None,
          ))
        }
      }
    }
  }
}

pub fn parsear_texto_ou_comando(raw_text: String) -> mensagem.Conteudo {
  let trimmed = string.trim(raw_text)
  case trimmed {
    "/" <> rest | "." <> rest -> {
      let rest = string.trim(rest)
      let #(nome, args) = case string.split_once(rest, " ") {
        Ok(#(n, a)) -> #(n, string.trim(a))
        Error(_) -> #(rest, "")
      }
      // Remove @botname de comandos como "/start@AmelieBot"
      let nome_limpo = case string.split_once(nome, "@") {
        Ok(#(n, _)) -> n
        Error(_) -> nome
      }
      mensagem.Comando(string.lowercase(nome_limpo), args)
    }
    _ -> mensagem.Texto(trimmed)
  }
}

fn telegram_update_decoder() -> decode.Decoder(TelegramUpdate) {
  use update_id <- decode.field("update_id", decode.int)
  use message <- decode.optional_field(
    "message",
    None,
    telegram_message_decoder() |> decode.map(Some),
  )
  decode.success(TelegramUpdate(update_id: update_id, message: message))
}

fn telegram_message_decoder() -> decode.Decoder(TelegramMessage) {
  use message_id <- decode.field("message_id", decode.int)
  use date <- decode.field("date", decode.int)
  use chat_id <- decode.then(decode.at(["chat", "id"], decode.int))
  use chat_type <- decode.then(decode.at(["chat", "type"], decode.string))
  use from_id <- decode.optional_field(
    "from",
    None,
    decode.at(["id"], decode.int) |> decode.map(Some),
  )
  use text <- decode.optional_field(
    "text",
    None,
    decode.string |> decode.map(Some),
  )
  decode.success(TelegramMessage(
    message_id: message_id,
    date: date,
    chat_id: chat_id,
    chat_type: chat_type,
    from_id: from_id,
    text: text,
  ))
}

fn get_updates_response_decoder() -> decode.Decoder(List(TelegramUpdate)) {
  decode.at(["result"], decode.list(telegram_update_decoder()))
}
