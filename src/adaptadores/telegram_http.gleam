// Adaptador HTTP para a Telegram Bot API.
// Implementa MensageiroPorta chamando api.telegram.org diretamente.

import dominio/erro.{type Erro}
import gleam/dynamic/decode
import gleam/http
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/json
import gleam/result
import gleam/string
import logging
import portas/mensageiro_porta.{type MensageiroPorta, MensageiroPorta}

const base_url = "https://api.telegram.org"

pub fn criar(bot_token: String) -> MensageiroPorta {
  MensageiroPorta(
    enviar: fn(chat_id, texto) { enviar_mensagem(bot_token, chat_id, texto) },
    enviar_citando: fn(chat_id, quoted_id, _quoted_sender, texto) {
      enviar_citando(bot_token, chat_id, quoted_id, texto)
    },
    reagir: fn(chat_id, message_id, _sender, emoji) {
      reagir(bot_token, chat_id, message_id, emoji)
    },
  )
}

// ---------------------------------------------------------------------------
// Download de mídia via Bot API (getFile + HTTP GET)
// ---------------------------------------------------------------------------

pub fn baixar_arquivo(
  bot_token: String,
  file_id: String,
) -> Result(BitArray, Erro) {
  // 1. Chama getFile para obter file_path
  use file_path <- result.try(obter_file_path(bot_token, file_id))
  // 2. Baixa o arquivo
  let url = base_url <> "/file/bot" <> bot_token <> "/" <> file_path
  use req <- result.try(
    request.to(url)
    |> result.map_error(fn(_) { erro.ErroComunicacao("url inválida") }),
  )
  let req = request.set_body(req, <<>>)
  use resp <- result.try(
    httpc.send_bits(req)
    |> result.map_error(fn(_) {
      erro.ErroComunicacao("falha ao baixar arquivo do Telegram")
    }),
  )
  case resp.status {
    200 -> Ok(resp.body)
    status ->
      Error(erro.ErroComunicacao(
        "Telegram retornou status "
        <> int.to_string(status)
        <> " ao baixar arquivo",
      ))
  }
}

// ---------------------------------------------------------------------------
// Internos
// ---------------------------------------------------------------------------

pub fn normalizar_id(id: String) -> String {
  case string.starts_with(id, "tg:") {
    True -> string.drop_start(id, 3)
    False -> id
  }
}

pub fn enviar_chat_action(
  bot_token: String,
  chat_id: String,
  action: String,
) -> Result(Nil, Erro) {
  let target_id = normalizar_id(chat_id)
  let body =
    json.object([
      #("chat_id", json.string(target_id)),
      #("action", json.string(action)),
    ])
    |> json.to_string
  post(bot_token, "/sendChatAction", body)
}

pub fn enviar_mensagem(
  bot_token: String,
  chat_id: String,
  texto: String,
) -> Result(Nil, Erro) {
  let target_id = normalizar_id(chat_id)
  let body =
    json.object([
      #("chat_id", json.string(target_id)),
      #("text", json.string(texto)),
      #("parse_mode", json.string("Markdown")),
    ])
    |> json.to_string
  post(bot_token, "/sendMessage", body)
}

fn enviar_citando(
  bot_token: String,
  chat_id: String,
  quoted_id: String,
  texto: String,
) -> Result(Nil, Erro) {
  let target_id = normalizar_id(chat_id)
  let reply_id = int.parse(normalizar_id(quoted_id)) |> result.unwrap(0)
  let body =
    json.object([
      #("chat_id", json.string(target_id)),
      #("text", json.string(texto)),
      #("parse_mode", json.string("Markdown")),
      #("reply_to_message_id", json.int(reply_id)),
    ])
    |> json.to_string
  post(bot_token, "/sendMessage", body)
}

pub fn mapear_emoji_telegram(emoji: String) -> String {
  case emoji {
    "⌛" | "⏳" -> "🤔"
    "🆗" -> "👍"
    outro -> outro
  }
}

fn reagir(
  bot_token: String,
  chat_id: String,
  message_id: String,
  emoji: String,
) -> Result(Nil, Erro) {
  let target_id = normalizar_id(chat_id)
  let msg_id = int.parse(normalizar_id(message_id)) |> result.unwrap(0)
  let emoji_tg = mapear_emoji_telegram(emoji)
  let body =
    json.object([
      #("chat_id", json.string(target_id)),
      #("message_id", json.int(msg_id)),
      #(
        "reaction",
        json.preprocessed_array([
          json.object([
            #("type", json.string("emoji")),
            #("emoji", json.string(emoji_tg)),
          ]),
        ]),
      ),
    ])
    |> json.to_string
  // Envia reação para a Bot API do Telegram
  let res = post(bot_token, "/setMessageReaction", body)
  case res {
    Ok(_) -> {
      logging.log(
        logging.Info,
        "Telegram reação enviada: chat="
          <> target_id
          <> " msg="
          <> int.to_string(msg_id)
          <> " emoji="
          <> emoji_tg,
      )
      Ok(Nil)
    }
    Error(e) -> {
      logging.log(
        logging.Warning,
        "Telegram reação falhou: chat="
          <> target_id
          <> " msg="
          <> int.to_string(msg_id)
          <> " emoji="
          <> emoji_tg
          <> " erro="
          <> erro.descricao(e),
      )
      Error(e)
    }
  }
}

fn obter_file_path(bot_token: String, file_id: String) -> Result(String, Erro) {
  let body =
    json.object([#("file_id", json.string(file_id))])
    |> json.to_string
  let url = base_url <> "/bot" <> bot_token <> "/getFile"
  use req <- result.try(
    request.to(url)
    |> result.map_error(fn(_) { erro.ErroComunicacao("url inválida") }),
  )
  let req =
    req
    |> request.set_method(http.Post)
    |> request.set_header("content-type", "application/json")
    |> request.set_body(body)
  use resp <- result.try(
    httpc.send(req)
    |> result.map_error(fn(e) {
      logging.log(
        logging.Warning,
        "Telegram getFile httpc.send falhou: " <> string.inspect(e),
      )
      erro.ErroComunicacao("falha ao contatar Telegram (getFile)")
    }),
  )
  case resp.status {
    200 -> {
      let decoder = decode.at(["result", "file_path"], decode.string)
      json.parse(resp.body, decoder)
      |> result.map_error(fn(_) {
        erro.ErroComunicacao("resposta getFile inválida")
      })
    }
    status -> {
      logging.log(
        logging.Warning,
        "Telegram getFile status="
          <> int.to_string(status)
          <> " resp="
          <> resp.body,
      )
      Error(erro.ErroComunicacao(
        "Telegram getFile retornou status " <> int.to_string(status),
      ))
    }
  }
}

fn post(bot_token: String, method: String, body: String) -> Result(Nil, Erro) {
  let url = base_url <> "/bot" <> bot_token <> method
  use req <- result.try(
    request.to(url)
    |> result.map_error(fn(_) { erro.ErroComunicacao("url inválida") }),
  )
  let req =
    req
    |> request.set_method(http.Post)
    |> request.set_header("content-type", "application/json")
    |> request.set_body(body)
  use resp <- result.try(
    httpc.send(req)
    |> result.map_error(fn(e) {
      logging.log(
        logging.Warning,
        "Telegram post "
          <> method
          <> " httpc.send falhou: "
          <> string.inspect(e),
      )
      erro.ErroComunicacao("falha ao contatar Telegram")
    }),
  )
  case resp.status {
    s if s >= 200 && s < 300 -> Ok(Nil)
    400 -> {
      // Retry sem parse_mode caso Markdown inválido
      case string.contains(body, "parse_mode") {
        True -> {
          let body_sem_parse =
            string.replace(body, "\"parse_mode\":\"Markdown\",", "")
          let url2 = base_url <> "/bot" <> bot_token <> method
          use req2 <- result.try(
            request.to(url2)
            |> result.map_error(fn(_) { erro.ErroComunicacao("url inválida") }),
          )
          let req2 =
            req2
            |> request.set_method(http.Post)
            |> request.set_header("content-type", "application/json")
            |> request.set_body(body_sem_parse)
          use resp2 <- result.try(
            httpc.send(req2)
            |> result.map_error(fn(_) {
              erro.ErroComunicacao("falha ao contatar Telegram (retry)")
            }),
          )
          case resp2.status {
            s2 if s2 >= 200 && s2 < 300 -> Ok(Nil)
            status2 -> {
              logging.log(
                logging.Warning,
                "Telegram post "
                  <> method
                  <> " status="
                  <> int.to_string(status2)
                  <> " resp="
                  <> resp2.body,
              )
              Error(erro.ErroComunicacao(
                "Telegram retornou status " <> int.to_string(status2),
              ))
            }
          }
        }
        False -> {
          logging.log(
            logging.Warning,
            "Telegram post "
              <> method
              <> " status=400 resp="
              <> resp.body
              <> " body="
              <> body,
          )
          Error(erro.ErroComunicacao(
            "Telegram retornou status 400: " <> resp.body,
          ))
        }
      }
    }
    status -> {
      logging.log(
        logging.Warning,
        "Telegram post "
          <> method
          <> " status="
          <> int.to_string(status)
          <> " resp="
          <> resp.body,
      )
      Error(erro.ErroComunicacao(
        "Telegram retornou status " <> int.to_string(status),
      ))
    }
  }
}
