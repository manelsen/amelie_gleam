// Adaptador HTTP para o bridge Whatsmeow (Go).
// Implementa MensageiroPorta chamando o microserviço local.

import dominio/erro.{type Erro}
import gleam/http
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/json
import gleam/result
import portas/mensageiro_porta.{type MensageiroPorta, MensageiroPorta}

pub fn criar(base_url: String) -> MensageiroPorta {
  MensageiroPorta(
    enviar: fn(chat_id, texto) { enviar_mensagem(base_url, chat_id, texto) },
    enviar_citando: fn(chat_id, quoted_id, quoted_sender, texto) {
      enviar_citando(base_url, chat_id, quoted_id, quoted_sender, texto)
    },
    reagir: fn(chat_id, message_id, sender, emoji) {
      reagir(base_url, chat_id, message_id, sender, emoji)
    },
  )
}

fn enviar_citando(
  base_url: String,
  chat_id: String,
  quoted_id: String,
  quoted_sender: String,
  texto: String,
) -> Result(Nil, Erro) {
  let body =
    json.object([
      #("chat_id", json.string(chat_id)),
      #("text", json.string(texto)),
      #("quoted_message_id", json.string(quoted_id)),
      #("quoted_sender", json.string(quoted_sender)),
    ])
    |> json.to_string
  post(base_url, body)
}

fn enviar_mensagem(
  base_url: String,
  chat_id: String,
  texto: String,
) -> Result(Nil, Erro) {
  let body =
    json.object([
      #("chat_id", json.string(chat_id)),
      #("text", json.string(texto)),
    ])
    |> json.to_string
  post(base_url, body)
}

fn reagir(
  base_url: String,
  chat_id: String,
  message_id: String,
  sender: String,
  emoji: String,
) -> Result(Nil, Erro) {
  let body =
    json.object([
      #("chat_id", json.string(chat_id)),
      #("message_id", json.string(message_id)),
      #("sender", json.string(sender)),
      #("emoji", json.string(emoji)),
    ])
    |> json.to_string
  use req <- result.try(
    request.to(base_url <> "/react")
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
      erro.ErroComunicacao("falha ao contatar whatsmeow bridge")
    }),
  )
  case resp.status {
    200 -> Ok(Nil)
    status ->
      Error(erro.ErroComunicacao(
        "whatsmeow retornou status " <> int.to_string(status),
      ))
  }
}

fn post(base_url: String, body: String) -> Result(Nil, Erro) {
  use req <- result.try(
    request.to(base_url <> "/send")
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
      erro.ErroComunicacao("falha ao contatar whatsmeow bridge")
    }),
  )

  case resp.status {
    200 -> Ok(Nil)
    status ->
      Error(erro.ErroComunicacao(
        "whatsmeow retornou status " <> int.to_string(status),
      ))
  }
}
