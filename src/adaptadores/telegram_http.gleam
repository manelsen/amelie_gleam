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
import portas/mensageiro_porta.{type MensageiroPorta, MensageiroPorta}

const base_url = "https://api.telegram.org"

pub fn criar(bot_token: String) -> MensageiroPorta {
  MensageiroPorta(
    enviar: fn(chat_id, texto) {
      enviar_mensagem(bot_token, chat_id, texto)
    },
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
  let url =
    base_url <> "/file/bot" <> bot_token <> "/" <> file_path
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
        "Telegram retornou status " <> int.to_string(status) <> " ao baixar arquivo",
      ))
  }
}

// ---------------------------------------------------------------------------
// Internos
// ---------------------------------------------------------------------------

fn enviar_mensagem(
  bot_token: String,
  chat_id: String,
  texto: String,
) -> Result(Nil, Erro) {
  let body =
    json.object([
      #("chat_id", json.string(chat_id)),
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
  // quoted_id vem como string; Telegram espera inteiro
  let reply_id = int.parse(quoted_id) |> result.unwrap(0)
  let body =
    json.object([
      #("chat_id", json.string(chat_id)),
      #("text", json.string(texto)),
      #("parse_mode", json.string("Markdown")),
      #("reply_to_message_id", json.int(reply_id)),
    ])
    |> json.to_string
  post(bot_token, "/sendMessage", body)
}

fn reagir(
  bot_token: String,
  chat_id: String,
  message_id: String,
  emoji: String,
) -> Result(Nil, Erro) {
  let msg_id = int.parse(message_id) |> result.unwrap(0)
  let body =
    json.object([
      #("chat_id", json.string(chat_id)),
      #("message_id", json.int(msg_id)),
      #(
        "reaction",
        json.preprocessed_array([
          json.object([
            #("type", json.string("emoji")),
            #("emoji", json.string(emoji)),
          ]),
        ]),
      ),
    ])
    |> json.to_string
  // Fire-and-forget — ignora erros de reação (emoji não suportado, etc.)
  let _ = post(bot_token, "/setMessageReaction", body)
  Ok(Nil)
}

fn obter_file_path(
  bot_token: String,
  file_id: String,
) -> Result(String, Erro) {
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
    |> result.map_error(fn(_) {
      erro.ErroComunicacao("falha ao contatar Telegram (getFile)")
    }),
  )
  case resp.status {
    200 -> {
      let decoder =
        decode.at(["result", "file_path"], decode.string)
      json.parse(resp.body, decoder)
      |> result.map_error(fn(_) {
        erro.ErroComunicacao("resposta getFile inválida")
      })
    }
    status ->
      Error(erro.ErroComunicacao(
        "Telegram getFile retornou status " <> int.to_string(status),
      ))
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
    |> result.map_error(fn(_) {
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
            status2 ->
              Error(erro.ErroComunicacao(
                "Telegram retornou status " <> int.to_string(status2),
              ))
          }
        }
        False ->
          Error(erro.ErroComunicacao(
            "Telegram retornou status 400",
          ))
      }
    }
    status ->
      Error(erro.ErroComunicacao(
        "Telegram retornou status " <> int.to_string(status),
      ))
  }
}
