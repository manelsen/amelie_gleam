// Adaptador HTTP para o bridge Whatsmeow (Go).
// Implementa MensageiroPorta e PontePorta chamando o microserviço local.

import dominio/erro.{type Erro}
import gleam/dynamic/decode
import gleam/http
import gleam/http/request.{type Request}
import gleam/httpc
import gleam/int
import gleam/json
import gleam/result
import gleam/string
import portas/mensageiro_porta.{type MensageiroPorta, MensageiroPorta}
import portas/ponte_porta.{
  type PontePorta, type StatusPonte, PontePorta, StatusPonte,
}

/// Onde fica a ponte e o segredo que autentica cada requisição a ela.
pub type Conexao {
  Conexao(url: String, token: String)
}

fn autenticar(req: Request(a), conexao: Conexao) -> Request(a) {
  request.set_header(req, ponte_porta.cabecalho_token, conexao.token)
}

pub fn criar(conexao: Conexao) -> MensageiroPorta {
  MensageiroPorta(
    enviar: fn(chat_id, texto) { enviar_mensagem(conexao, chat_id, texto) },
    enviar_citando: fn(chat_id, quoted_id, quoted_sender, texto) {
      enviar_citando(conexao, chat_id, quoted_id, quoted_sender, texto)
    },
    reagir: fn(chat_id, message_id, sender, emoji) {
      reagir(conexao, chat_id, message_id, sender, emoji)
    },
  )
}

pub fn criar_ponte(conexao: Conexao) -> PontePorta {
  PontePorta(
    checar_status: fn() { checar_status(conexao) },
    pedir_codigo_pareamento: fn(telefone) {
      pedir_codigo_pareamento(conexao, telefone)
    },
    resetar_sessao: fn(telefone) { resetar_sessao(conexao, telefone) },
    buscar_pagina: fn(url) { buscar_pagina(conexao, url) },
  )
}

fn enviar_citando(
  conexao: Conexao,
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
  post(conexao, body)
}

fn enviar_mensagem(
  conexao: Conexao,
  chat_id: String,
  texto: String,
) -> Result(Nil, Erro) {
  let body =
    json.object([
      #("chat_id", json.string(chat_id)),
      #("text", json.string(texto)),
    ])
    |> json.to_string
  post(conexao, body)
}

fn reagir(
  conexao: Conexao,
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
    request.to(conexao.url <> "/react")
    |> result.map_error(fn(_) { erro.ErroComunicacao("url inválida") }),
  )
  let req =
    req
    |> request.set_method(http.Post)
    |> request.set_header("content-type", "application/json")
    |> request.set_body(body)
  use resp <- result.try(
    httpc.send(autenticar(req, conexao))
    |> result.map_error(fn(error) {
      erro.ErroComunicacao(descrever_erro_transporte(error))
    }),
  )
  interpretar_resposta(resp.status, resp.body)
}

fn post(conexao: Conexao, body: String) -> Result(Nil, Erro) {
  use req <- result.try(
    request.to(conexao.url <> "/send")
    |> result.map_error(fn(_) { erro.ErroComunicacao("url inválida") }),
  )

  let req =
    req
    |> request.set_method(http.Post)
    |> request.set_header("content-type", "application/json")
    |> request.set_body(body)

  use resp <- result.try(
    httpc.send(autenticar(req, conexao))
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

pub fn checar_status(conexao: Conexao) -> Result(StatusPonte, Erro) {
  use req <- result.try(
    request.to(conexao.url <> "/health")
    |> result.map_error(fn(_) { erro.ErroComunicacao("url inválida") }),
  )
  let req = req |> request.set_method(http.Get)
  use resp <- result.try(
    httpc.send(autenticar(req, conexao))
    |> result.map_error(fn(err) {
      erro.ErroComunicacao(descrever_erro_transporte(err))
    }),
  )
  let decoder = {
    use logged_in <- decode.optional_field("logged_in", False, decode.bool)
    decode.success(StatusPonte(conectado: True, logado: logged_in))
  }
  json.parse(resp.body, decoder)
  |> result.map_error(fn(_) {
    erro.ErroComunicacao("resposta de health inválida")
  })
}

pub fn pedir_codigo_pareamento(
  conexao: Conexao,
  phone: String,
) -> Result(String, String) {
  let body =
    json.object([#("phone", json.string(phone))])
    |> json.to_string
  let req =
    request.to(conexao.url <> "/pair-phone")
    |> result.unwrap(request.new())
    |> request.set_method(http.Post)
    |> request.set_header("content-type", "application/json")
    |> request.set_body(body)
  case httpc.send(autenticar(req, conexao)) {
    Error(err) -> Error(descrever_erro_transporte(err))
    Ok(resp) -> {
      let decoder_sucesso = {
        use code <- decode.field("code", decode.string)
        decode.success(code)
      }
      let decoder_erro = {
        use err <- decode.field("error", decode.string)
        decode.success(err)
      }
      case json.parse(resp.body, decoder_sucesso) {
        Ok(code) -> Ok(code)
        Error(_) ->
          case json.parse(resp.body, decoder_erro) {
            Ok(msg) -> Error(msg)
            Error(_) -> Error("status " <> int.to_string(resp.status))
          }
      }
    }
  }
}

pub fn resetar_sessao(conexao: Conexao, phone: String) -> Result(Nil, String) {
  let body = case phone {
    "" -> "{}"
    p ->
      json.object([#("phone", json.string(p))])
      |> json.to_string
  }
  let req =
    request.to(conexao.url <> "/reset-session")
    |> result.unwrap(request.new())
    |> request.set_method(http.Post)
    |> request.set_header("content-type", "application/json")
    |> request.set_body(body)
  case httpc.send(autenticar(req, conexao)) {
    Error(err) -> Error(descrever_erro_transporte(err))
    Ok(resp) -> {
      case resp.status {
        200 -> Ok(Nil)
        status -> Error("status " <> int.to_string(status))
      }
    }
  }
}

/// O bridge resolve e fixa o IP público de cada conexão e redirecionamento.
pub fn buscar_pagina(conexao: Conexao, url: String) -> Result(String, Erro) {
  use req <- result.try(
    request.to(conexao.url <> "/fetch")
    |> result.map_error(fn(_) { erro.ErroComunicacao("URL do bridge inválida") }),
  )
  let req =
    req
    |> request.set_method(http.Post)
    |> request.set_header("content-type", "application/json")
    |> request.set_body(
      json.object([#("url", json.string(url))]) |> json.to_string,
    )
    |> autenticar(conexao)
  use resp <- result.try(
    httpc.send(req)
    |> result.map_error(fn(err) {
      erro.ErroComunicacao(descrever_erro_transporte(err))
    }),
  )
  case resp.status {
    200 -> Ok(resp.body)
    _ ->
      Error(erro.ErroComunicacao("Não foi possível buscar a página pública."))
  }
}
