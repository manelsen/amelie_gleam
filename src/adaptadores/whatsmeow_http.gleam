// Adaptador HTTP para o bridge Whatsmeow (Go).
// Implementa WhatsappPorta chamando o microserviço local.

import dominio/erro.{type Erro}
import gleam/http
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/json
import gleam/result
import portas/whatsapp_porta.{type WhatsappPorta, WhatsappPorta}

pub fn criar(base_url: String) -> WhatsappPorta {
  WhatsappPorta(enviar: fn(chat_id, texto) {
    enviar_mensagem(base_url, chat_id, texto)
  })
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
