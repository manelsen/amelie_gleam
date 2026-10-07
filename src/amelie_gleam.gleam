import adaptadores/config_sqlite
import adaptadores/gemini_http
import adaptadores/grupo_sqlite
import adaptadores/historico_sqlite
import adaptadores/openrouter_http
import adaptadores/prompt_sqlite
import adaptadores/roteador_mensageiro
import adaptadores/telegram_http
import adaptadores/telegram_webhook
import adaptadores/transacao_sqlite
import adaptadores/usuario_sqlite
import adaptadores/whatsmeow_http
import core/ia_dispatcher
import dominio/mensagem.{type Mensagem, Mensagem, Texto}
import dominio/providers_config
import gleam/bit_array
import gleam/bytes_tree
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http/request.{type Request}
import gleam/http/response
import gleam/int
import gleam/json
import gleam/option
import gleam/result
import gleam/string
import mist.{type Connection, type ResponseData}
import shell/cache_ia
import shell/circuit_breaker
import shell/fila_midia
import shell/fila_offline
import shell/handler_mensagem.{type Portas, Portas}
import shell/ia_resiliente
import shell/manutencao
import shell/metricas
import shell/telegram_poller
import sqlight

import dot_env
import logging

// ---------------------------------------------------------------------------
// FFI — variáveis de ambiente
// ---------------------------------------------------------------------------

@external(erlang, "amelie_gleam_ffi", "get_env")
fn get_env(name: String) -> Result(String, Nil)

@external(erlang, "amelie_gleam_ffi", "spawn_fn")
fn spawn_fn(f: fn() -> a) -> Nil

@external(erlang, "amelie_gleam_ffi", "read_file")
fn read_file(path: String) -> Result(BitArray, String)

@external(erlang, "file", "delete")
fn delete_file(path: String) -> Result(Nil, ErlFileError)

type ErlFileError

/// Webhook decodificado. `arquivo` aponta para a mídia que o bridge gravou em
/// disco e que ainda precisa ser lida para preencher `msg.corpo`.
type Webhook {
  Webhook(msg: Mensagem, arquivo: option.Option(String))
}

pub fn main() {
  dot_env.new()
  |> dot_env.load

  logging.configure()

  let gemini_api_key =
    get_env("GEMINI_API_KEY")
    |> result.unwrap(or: "")
  let openrouter_api_key =
    get_env("OPENROUTER_API_KEY")
    |> result.unwrap(or: "")
  let telegram_bot_token =
    get_env("TELEGRAM_BOT_TOKEN")
    |> result.unwrap(or: "")
  let telegram_secret_token =
    get_env("TELEGRAM_SECRET_TOKEN")
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
  let offline_retry_interval_str =
    get_env("OFFLINE_RETRY_INTERVAL_MS")
    |> result.unwrap(or: "30000")
  let port =
    int.parse(port_str)
    |> result.unwrap(or: 4000)
  let offline_retry_interval_ms =
    int.parse(offline_retry_interval_str)
    |> result.unwrap(or: 30_000)

  let providers_config =
    providers_config.ler_arquivo("./config/providers.yaml")
    |> result.unwrap(providers_config.padrao())

  use conn <- sqlight.with_connection(db_path)

  let cb_gemini =
    circuit_breaker.iniciar()
    |> result.lazy_unwrap(fn() {
      panic as "falha ao iniciar circuit breaker gemini"
    })
  let cb_openrouter =
    circuit_breaker.iniciar()
    |> result.lazy_unwrap(fn() {
      panic as "falha ao iniciar circuit breaker openrouter"
    })
  let cache_gemini =
    cache_ia.iniciar()
    |> result.lazy_unwrap(fn() { panic as "falha ao iniciar cache gemini" })
  let cache_openrouter =
    cache_ia.iniciar()
    |> result.lazy_unwrap(fn() { panic as "falha ao iniciar cache openrouter" })

  let gemini_ia =
    gemini_http.criar(gemini_api_key)
    |> ia_resiliente.envolver(cb_gemini, cache_gemini)
  let openrouter_ia =
    openrouter_http.criar(openrouter_api_key)
    |> ia_resiliente.envolver(cb_openrouter, cache_openrouter)
  let ia_dispatcher =
    ia_dispatcher.IADispatcher(gemini: gemini_ia, openrouter: openrouter_ia)
  let whatsapp = whatsmeow_http.criar(bridge_url)
  let telegram = telegram_http.criar(telegram_bot_token)
  let mensageiro = roteador_mensageiro.criar(whatsapp, telegram)
  let config_p = config_sqlite.criar(conn)
  let historico_p = historico_sqlite.criar(conn)
  let prompts_p = prompt_sqlite.criar(conn)
  let usuarios_p = usuario_sqlite.criar(conn)
  let grupos_p = grupo_sqlite.criar(conn)
  let transacoes_p = transacao_sqlite.criar(conn)

  let fila =
    fila_midia.iniciar_todas()
    |> result.lazy_unwrap(fn() { panic as "falha ao iniciar filas de mídia" })

  let metricas_actor =
    metricas.iniciar()
    |> result.lazy_unwrap(fn() { panic as "falha ao iniciar métricas" })

  let fila_offline_actor =
    fila_offline.iniciar(transacoes_p, mensageiro, 3)
    |> result.lazy_unwrap(fn() { panic as "falha ao iniciar fila offline" })
  let _ =
    fila_offline.agendar_processamento(
      fila_offline_actor,
      offline_retry_interval_ms,
    )
  let _ = manutencao.agendar_padrao(transacoes_p)

  let portas =
    Portas(
      mensageiro: mensageiro,
      ia_dispatcher: ia_dispatcher,
      config: config_p,
      historico: historico_p,
      fila: fila,
      prompts: prompts_p,
      metricas: metricas_actor,
      usuarios: usuarios_p,
      grupos: grupos_p,
      transacoes: transacoes_p,
      providers_config: providers_config,
    )

  let _ = telegram_poller.iniciar(telegram_bot_token, portas)

  let assert Ok(_) =
    mist.new(fn(req) { handle_request(req, portas, telegram_secret_token) })
    |> mist.port(port)
    |> mist.bind("0.0.0.0")
    |> mist.start

  process.sleep_forever()
}

// ---------------------------------------------------------------------------
// HTTP handlers
// ---------------------------------------------------------------------------

fn handle_request(
  req: Request(Connection),
  portas: Portas,
  telegram_secret: String,
) -> response.Response(ResponseData) {
  case req.path {
    "/webhook" -> handle_webhook(req, portas)
    "/webhook/telegram" -> handle_telegram_webhook(req, portas, telegram_secret)
    "/health" -> json_response(200, "{\"status\":\"ok\"}")
    _ -> json_response(404, "{\"error\":\"not found\"}")
  }
}

fn handle_telegram_webhook(
  req: Request(Connection),
  portas: Portas,
  secret_token: String,
) -> response.Response(ResponseData) {
  case secret_token {
    "" -> processar_telegram_body(req, portas)
    expected -> {
      case request.get_header(req, "x-telegram-bot-api-secret-token") {
        Ok(token) if token == expected -> processar_telegram_body(req, portas)
        _ -> json_response(401, "{\"error\":\"unauthorized\"}")
      }
    }
  }
}

fn processar_telegram_body(
  req: Request(Connection),
  portas: Portas,
) -> response.Response(ResponseData) {
  case mist.read_body(req, 1024 * 1024) {
    Error(_) -> json_response(400, "{\"error\":\"failed to read body\"}")
    Ok(req_with_body) ->
      case telegram_webhook.parsear_update(req_with_body.body) {
        Error(_) ->
          json_response(400, "{\"error\":\"invalid telegram payload\"}")
        Ok(option.None) -> json_response(200, "{\"ok\":true,\"ignored\":true}")
        Ok(option.Some(msg)) -> {
          spawn_fn(fn() {
            handler_mensagem.handle(msg, portas)
          })
          json_response(200, "{\"ok\":true}")
        }
      }
  }
}

fn handle_webhook(
  req: Request(Connection),
  portas: Portas,
) -> response.Response(ResponseData) {
  case mist.read_body(req, 20 * 1024 * 1024) {
    Error(_) -> json_response(400, "{\"error\":\"failed to read body\"}")
    Ok(req_with_body) ->
      case parse_webhook(req_with_body.body) {
        Error(_) -> json_response(400, "{\"error\":\"invalid payload\"}")
        Ok(webhook) -> {
          // Processa em processo isolado — webhook retorna imediatamente.
          // Evita bloquear o Mist durante chamadas à IA (2-10s).
          spawn_fn(fn() {
            handler_mensagem.handle(carregar_midia(webhook), portas)
          })
          json_response(202, "{\"ok\":true}")
        }
      }
  }
}

fn parse_webhook(body: BitArray) -> Result(Webhook, Nil) {
  case bit_array.to_string(body) {
    Error(_) -> Error(Nil)
    Ok(s) ->
      json.parse(s, mensagem_decoder())
      |> result.map_error(fn(_) { Nil })
  }
}

fn mensagem_decoder() -> decode.Decoder(Webhook) {
  use chat_id <- decode.field("chat_id", decode.string)
  use from <- decode.field("from", decode.string)
  use message_id <- decode.optional_field(
    "message_id",
    option.None,
    decode.string |> decode.map(option.Some),
  )
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

  let #(corpo, arquivo) = parsear_corpo(tipo, text, mime, dados, caminho)
  let msg =
    Mensagem(
      chat_id: chat_id,
      remetente: from,
      message_id: message_id,
      corpo: corpo,
      timestamp: ts,
      em_grupo: em_grupo,
      nome_grupo: nome_grupo,
      menciona_bot: menciona,
      legenda: caption,
    )
  decode.success(Webhook(msg: msg, arquivo: arquivo))
}

fn parsear_corpo(
  tipo: String,
  text: String,
  mime: String,
  dados: String,
  caminho_temp: String,
) -> #(mensagem.Conteudo, option.Option(String)) {
  // Mídia chega por arquivo (`caminho_temp`); `dados` em base64 só aparece em
  // payloads antigos que ainda estejam na fila do bridge.
  let #(bytes, arquivo) = case caminho_temp {
    "" -> #(
      bit_array.base64_decode(dados) |> result.unwrap(or: <<>>),
      option.None,
    )
    _ -> #(<<>>, option.Some(caminho_temp))
  }
  case tipo {
    "imagem" -> #(mensagem.Imagem(mime: mime, dados: bytes), arquivo)
    "audio" -> #(mensagem.Audio(mime: mime, dados: bytes), arquivo)
    "documento" -> #(
      mensagem.Documento(mime: mime, dados: bytes, nome: text),
      arquivo,
    )
    "sticker" -> #(mensagem.Sticker(mime: mime, dados: bytes), arquivo)
    // Vídeo segue em disco até o upload para a IA; fila_midia apaga o arquivo.
    "video" -> #(
      mensagem.Video(caminho_temp: caminho_temp, mime: mime),
      option.None,
    )
    "midia_indisponivel" -> #(
      mensagem.MidiaIndisponivel(mensagem: text),
      option.None,
    )
    _ -> {
      let corpo = case string.trim(text) {
        "." <> rest -> {
          case string.split_once(rest, " ") {
            Ok(#(nome, args)) ->
              mensagem.Comando(string.lowercase(nome), string.trim(args))
            Error(_) -> mensagem.Comando(string.lowercase(rest), "")
          }
        }
        _ -> Texto(text)
      }
      #(corpo, option.None)
    }
  }
}

/// Lê do disco a mídia gravada pelo bridge e apaga o arquivo. Se a leitura
/// falhar, responde ao usuário em vez de processar mídia vazia.
fn carregar_midia(webhook: Webhook) -> Mensagem {
  case webhook.arquivo {
    option.None -> webhook.msg
    option.Some(caminho) -> {
      let corpo = case read_file(caminho) {
        Ok(bytes) -> com_bytes(webhook.msg.corpo, bytes)
        Error(motivo) -> {
          logging.log(
            logging.Warning,
            "Falha ao ler mídia temporária "
              <> caminho
              <> " de "
              <> webhook.msg.chat_id
              <> ": "
              <> motivo,
          )
          mensagem.MidiaIndisponivel(
            mensagem: "Não consegui ler a mídia que você enviou. Pode reenviar?",
          )
        }
      }
      let _ = delete_file(caminho)
      Mensagem(..webhook.msg, corpo: corpo)
    }
  }
}

fn com_bytes(corpo: mensagem.Conteudo, bytes: BitArray) -> mensagem.Conteudo {
  case corpo {
    mensagem.Imagem(mime: mime, ..) -> mensagem.Imagem(mime: mime, dados: bytes)
    mensagem.Audio(mime: mime, ..) -> mensagem.Audio(mime: mime, dados: bytes)
    mensagem.Documento(mime: mime, nome: nome, ..) ->
      mensagem.Documento(mime: mime, dados: bytes, nome: nome)
    mensagem.Sticker(mime: mime, ..) ->
      mensagem.Sticker(mime: mime, dados: bytes)
    outro -> outro
  }
}

fn json_response(status: Int, body: String) -> response.Response(ResponseData) {
  response.new(status)
  |> response.set_header("content-type", "application/json")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(body)))
}
