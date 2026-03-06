// Ponto de entrada — inicializa e conecta todos os componentes.

import adaptadores/config_sqlite
import adaptadores/gemini_http
import adaptadores/historico_sqlite
import adaptadores/whatsmeow_http
import dominio/mensagem.{type Mensagem, Mensagem, Texto}
import gleam/bit_array
import gleam/bytes_tree
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http/request.{type Request}
import gleam/http/response
import gleam/int
import gleam/json
import gleam/result
import mist.{type Connection, type ResponseData}
import shell/fila_midia
import shell/handler_mensagem.{type Portas, Portas}
import sqlight

// ---------------------------------------------------------------------------
// FFI — variáveis de ambiente
// ---------------------------------------------------------------------------

@external(erlang, "amelie_gleam_ffi", "get_env")
fn get_env(name: String) -> Result(String, Nil)

pub fn main() {
  let api_key =
    get_env("GEMINI_API_KEY")
    |> result.unwrap(or: "")
  let bridge_url =
    get_env("WHATSMEOW_URL")
    |> result.unwrap(or: "http://localhost:8080")
  let db_path =
    get_env("DB_PATH")
    |> result.unwrap(or: "./db/amelie.sqlite")
  let port_str =
    get_env("PORT")
    |> result.unwrap(or: "4000")
  let port =
    int.parse(port_str)
    |> result.unwrap(or: 4000)

  use conn <- sqlight.with_connection(db_path)

  let ia = gemini_http.criar(api_key)
  let whatsapp = whatsmeow_http.criar(bridge_url)
  let config_p = config_sqlite.criar(conn)
  let historico_p = historico_sqlite.criar(conn)

  let fila = case fila_midia.iniciar() {
    Ok(f) -> f
    Error(_) -> panic as "falha ao iniciar fila de mídia"
  }

  let portas =
    Portas(
      whatsapp: whatsapp,
      ia: ia,
      config: config_p,
      historico: historico_p,
      fila: fila,
    )

  let assert Ok(_) =
    mist.new(fn(req) { handle_request(req, portas) })
    |> mist.port(port)
    |> mist.start

  process.sleep_forever()
}

// ---------------------------------------------------------------------------
// HTTP handlers
// ---------------------------------------------------------------------------

fn handle_request(
  req: Request(Connection),
  portas: Portas,
) -> response.Response(ResponseData) {
  case req.path {
    "/webhook" -> handle_webhook(req, portas)
    "/health" -> json_response(200, "{\"status\":\"ok\"}")
    _ -> json_response(404, "{\"error\":\"not found\"}")
  }
}

fn handle_webhook(
  req: Request(Connection),
  portas: Portas,
) -> response.Response(ResponseData) {
  case mist.read_body(req, 1024 * 1024) {
    Error(_) -> json_response(400, "{\"error\":\"failed to read body\"}")
    Ok(req_with_body) ->
      case parse_webhook(req_with_body.body) {
        Error(_) -> json_response(400, "{\"error\":\"invalid payload\"}")
        Ok(msg) -> {
          let _ = handler_mensagem.handle(msg, portas)
          json_response(200, "{\"ok\":true}")
        }
      }
  }
}

fn parse_webhook(body: BitArray) -> Result(Mensagem, Nil) {
  case bit_array.to_string(body) {
    Error(_) -> Error(Nil)
    Ok(s) ->
      json.parse(s, mensagem_decoder())
      |> result.map_error(fn(_) { Nil })
  }
}

fn mensagem_decoder() -> decode.Decoder(Mensagem) {
  use chat_id <- decode.field("chat_id", decode.string)
  use from <- decode.field("from", decode.string)
  use text <- decode.field("text", decode.string)
  use ts <- decode.field("ts", decode.int)
  use em_grupo <- decode.field("em_grupo", decode.bool)
  decode.success(Mensagem(
    chat_id: chat_id,
    remetente: from,
    corpo: Texto(text),
    timestamp: ts,
    em_grupo: em_grupo,
    menciona_bot: False,
  ))
}

fn json_response(status: Int, body: String) -> response.Response(ResponseData) {
  response.new(status)
  |> response.set_header("content-type", "application/json")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(body)))
}
