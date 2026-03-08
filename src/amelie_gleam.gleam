import adaptadores/config_sqlite
import adaptadores/gemini_http
import adaptadores/grupo_sqlite
import adaptadores/historico_sqlite
import adaptadores/prompt_sqlite
import adaptadores/usuario_sqlite
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
import gleam/option
import gleam/string
import mist.{type Connection, type ResponseData}
import shell/fila_midia
import shell/handler_mensagem.{type Portas, Portas}
import shell/metricas
import sqlight

import dot_env
import logging

// ---------------------------------------------------------------------------
// FFI — variáveis de ambiente
// ---------------------------------------------------------------------------

@external(erlang, "amelie_gleam_ffi", "get_env")
fn get_env(name: String) -> Result(String, Nil)

pub fn main() {
  dot_env.new()
  |> dot_env.load
  
  logging.configure()

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
  let prompts_p = prompt_sqlite.criar(conn)
  let usuarios_p = usuario_sqlite.criar(conn)
  let grupos_p = grupo_sqlite.criar(conn)

  let fila = case fila_midia.iniciar_todas() {
    Ok(f) -> f
    Error(_) -> panic as "falha ao iniciar filas de mídia"
  }

  let metricas_actor = case metricas.iniciar() {
    Ok(m) -> m
    Error(_) -> panic as "falha ao iniciar métricas"
  }

  let portas =
    Portas(
      whatsapp: whatsapp,
      ia: ia,
      config: config_p,
      historico: historico_p,
      fila: fila,
      prompts: prompts_p,
      metricas: metricas_actor,
      usuarios: usuarios_p,
      grupos: grupos_p,
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
  use text <- decode.optional_field("text", "", decode.string)
  use ts <- decode.field("ts", decode.int)
  use em_grupo <- decode.field("em_grupo", decode.bool)
  use nome_grupo <- decode.optional_field(
    "nome_grupo",
    option.None,
    decode.string |> decode.map(option.Some),
  )
  use menciona <- decode.optional_field("menciona_bot", False, decode.bool)
  use caption <- decode.optional_field(
    "legenda",
    option.None,
    decode.string |> decode.map(option.Some),
  )
  
  use tipo <- decode.optional_field("tipo", "texto", decode.string)
  use mime <- decode.optional_field("mime", "", decode.string)
  use dados <- decode.optional_field("dados", "", decode.string)
  use caminho <- decode.optional_field("caminho_temp", "", decode.string)

  let corpo = parsear_corpo(tipo, text, mime, dados, caminho)
  decode.success(Mensagem(
    chat_id: chat_id,
    remetente: from,
    corpo: corpo,
    timestamp: ts,
    em_grupo: em_grupo,
    nome_grupo: nome_grupo,
    menciona_bot: menciona,
    legenda: caption,
  ))
}

fn parsear_corpo(
  tipo: String,
  text: String,
  mime: String,
  dados: String,
  caminho_temp: String,
) -> mensagem.Conteudo {
  case tipo {
    "imagem" -> {
      let b = bit_array.base64_decode(dados) |> result.unwrap(or: <<>>)
      mensagem.Imagem(mime: mime, dados: b)
    }
    "audio" -> {
      let b = bit_array.base64_decode(dados) |> result.unwrap(or: <<>>)
      mensagem.Audio(mime: mime, dados: b)
    }
    "documento" -> {
      let b = bit_array.base64_decode(dados) |> result.unwrap(or: <<>>)
      mensagem.Documento(mime: mime, dados: b, nome: text)
    }
    "video" -> {
      mensagem.Video(caminho_temp: caminho_temp, mime: mime)
    }
    _ -> {
      case string.trim(text) {
        "." <> rest -> {
          case string.split_once(rest, " ") {
            Ok(#(nome, args)) ->
              mensagem.Comando(string.lowercase(nome), string.trim(args))
            Error(_) -> mensagem.Comando(string.lowercase(rest), "")
          }
        }
        _ -> Texto(text)
      }
    }
  }
}

fn json_response(status: Int, body: String) -> response.Response(ResponseData) {
  response.new(status)
  |> response.set_header("content-type", "application/json")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(body)))
}
