// Busca e extrai texto de URLs para injeção no contexto da IA.
// Stripping de HTML é intencional mas básico — a IA lida bem com o restante.

import dominio/erro.{type Erro}
import gleam/http/request
import gleam/httpc
import gleam/list
import gleam/result
import gleam/string

const max_chars = 5000

pub fn buscar(url: String) -> Result(String, Erro) {
  use req <- result.try(
    request.to(url)
    |> result.map_error(fn(_) { erro.ErroComunicacao("URL inválida: " <> url) }),
  )

  let req =
    req
    |> request.set_header(
      "user-agent",
      "Mozilla/5.0 (compatible; Amelie-Bot/1.0)",
    )
    |> request.set_header("accept", "text/html,text/plain")

  use resp <- result.try(
    httpc.send(req)
    |> result.map_error(fn(_) {
      erro.ErroComunicacao("falha ao buscar URL: " <> url)
    }),
  )

  case resp.status {
    200 ->
      resp.body
      |> strip_html
      |> truncar(max_chars)
      |> Ok
    status ->
      Error(erro.ErroComunicacao(
        "URL retornou status "
        <> string.inspect(status)
        <> ": "
        <> url,
      ))
  }
}

// Remove tags HTML de forma simples: split em "<", descarta até ">"
fn strip_html(html: String) -> String {
  html
  |> string.split("<")
  |> list.index_map(fn(parte, i) {
    case i == 0 {
      True -> parte
      False ->
        case string.split_once(parte, ">") {
          Ok(#(_, apos)) -> " " <> apos
          Error(_) -> ""
        }
    }
  })
  |> string.join("")
  |> colapsar_espacos
  |> string.trim
}

fn colapsar_espacos(s: String) -> String {
  s
  |> string.split("\n")
  |> list.map(string.trim)
  |> list.filter(fn(linha) { linha != "" })
  |> string.join("\n")
}

fn truncar(s: String, max: Int) -> String {
  case string.length(s) > max {
    True -> string.slice(s, 0, max) <> "…"
    False -> s
  }
}
