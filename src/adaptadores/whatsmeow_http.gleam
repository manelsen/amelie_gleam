// Adaptador HTTP para o bridge Whatsmeow (Go).
// Implementa MensageiroPorta chamando o microserviço local.

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
    |> result.map_error(fn(error) {
      erro.ErroComunicacao(descrever_erro_transporte(error))
    }),
  )
  interpretar_resposta(resp.status, resp.body)
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
    |> result.map_error(fn(error) {
      erro.ErroComunicacao(descrever_erro_transporte(error))
    }),
  )

  interpretar_resposta(resp.status, resp.body)
}

fn interpretar_resposta(status: Int, body: String) -> Result(Nil, Erro) {
  case status {
    200 -> Ok(Nil)
    status -> Error(erro.ErroComunicacao(descrever_erro_http(status, body)))
  }
}

pub fn descrever_erro_http(status: Int, body: String) -> String {
  let prefixo = "whatsmeow retornou status " <> int.to_string(status)
  let decoder = {
    use codigo <- decode.then(decode.at(["code"], decode.string))
    use mensagem <- decode.then(decode.at(["error"], decode.string))
    decode.success(#(codigo, mensagem))
  }

  case json.parse(body, decoder) {
    Ok(#(codigo, mensagem)) -> prefixo <> " [" <> codigo <> "]: " <> mensagem
    Error(_) ->
      case string.trim(body) {
        "" -> prefixo
        detalhes -> prefixo <> ": " <> detalhes
      }
  }
}

pub fn descrever_erro_transporte(error: httpc.HttpError) -> String {
  case error {
    httpc.InvalidUtf8Response ->
      "resposta do whatsmeow bridge contém texto UTF-8 inválido"
    httpc.ResponseTimeout -> "timeout aguardando resposta do whatsmeow bridge"
    httpc.FailedToConnect(ipv4, ipv6) ->
      "falha ao conectar ao whatsmeow bridge (IPv4: "
      <> descrever_erro_conexao(ipv4)
      <> "; IPv6: "
      <> descrever_erro_conexao(ipv6)
      <> ")"
  }
}

fn descrever_erro_conexao(error: httpc.ConnectError) -> String {
  case error {
    httpc.Posix(codigo) -> "POSIX " <> codigo
    httpc.TlsAlert(codigo, detalhes) ->
      "TLS " <> codigo <> " (" <> detalhes <> ")"
  }
}
