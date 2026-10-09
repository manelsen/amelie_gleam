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
import shell/arvore_supervisao
import shell/fila_offline
import shell/handler_mensagem.{type Portas, Portas}
import shell/ia_resiliente
import shell/manutencao
import shell/metricas
import shell/seguranca_http
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

@external(erlang, "amelie_gleam_ffi", "read_bridge_media")
fn read_file(path: String) -> Result(BitArray, String)

@external(erlang, "amelie_gleam_ffi", "validate_bridge_media")
fn validar_arquivo(path: String) -> Result(String, String)

/// Webhook decodificado. `arquivo` aponta para a mídia que o bridge gravou em
/// disco e que ainda precisa ser lida para preencher `msg.corpo`.
type Webhook {
  Webhook(msg: Mensagem, arquivo: option.Option(String))
}

pub fn main() {
  dot_env.new()
  |> dot_env.load

  logging.configure()

  let bridge_token = seguranca_http.token_bridge()
  let assert True = string.byte_size(bridge_token) >= 32
    as "Defina BRIDGE_TOKEN com pelo menos 32 caracteres aleatórios"

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
  let telegram_admin_chat_id =
    get_env("TELEGRAM_ADMIN_CHAT_ID")
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
  let manutencao_intervalo_str =
    get_env("MANUTENCAO_INTERVALO_MS")
    |> result.unwrap(or: "3600000")
  let manutencao_intervalo_ms =
    int.parse(manutencao_intervalo_str)
    |> result.unwrap(or: 3_600_000)

  let providers_config =
    providers_config.ler_arquivo("./config/providers.yaml")
    |> result.unwrap(providers_config.padrao())

  use conn <- sqlight.with_connection(db_path)

  let config_p = config_sqlite.criar(conn)
  let historico_p = historico_sqlite.criar(conn)
  let prompts_p = prompt_sqlite.criar(conn)
  let usuarios_p = usuario_sqlite.criar(conn)
  let grupos_p = grupo_sqlite.criar(conn)
  let transacoes_p = transacao_sqlite.criar(conn)
  let whatsapp = whatsmeow_http.criar(bridge_url)
  let telegram = telegram_http.criar(telegram_bot_token)
  let mensageiro = roteador_mensageiro.criar(whatsapp, telegram)

  let #(_supervisor, procs) =
    arvore_supervisao.iniciar(transacoes_p, mensageiro)
    |> result.lazy_unwrap(fn() {
      panic as "falha ao iniciar árvore de supervisão de processos de suporte"
    })

  let gemini_ia =
    gemini_http.criar(gemini_api_key)
    |> ia_resiliente.envolver(procs.cb_gemini, procs.cache_gemini)
  let openrouter_ia =
    openrouter_http.criar(openrouter_api_key)
    |> ia_resiliente.envolver(procs.cb_openrouter, procs.cache_openrouter)
  let ia_dispatcher =
    ia_dispatcher.IADispatcher(gemini: gemini_ia, openrouter: openrouter_ia)

  let _ =
    fila_offline.agendar_processamento(
      procs.fila_offline,
      offline_retry_interval_ms,
    )
  let _ = manutencao.agendar(transacoes_p, manutencao_intervalo_ms)

  let portas =
    Portas(
      mensageiro: mensageiro,
      ia_dispatcher: ia_dispatcher,
      config: config_p,
      historico: historico_p,
      fila: procs.fila,
      prompts: prompts_p,
      metricas: procs.metricas,
      usuarios: usuarios_p,
      grupos: grupos_p,
      transacoes: transacoes_p,
      providers_config: providers_config,
    )

  let _ = telegram_poller.iniciar(telegram_bot_token, portas)

  let assert Ok(_) =
    mist.new(fn(req) {
      handle_request(
        req,
        portas,
        conn,
        bridge_url,
        telegram_secret_token,
        telegram_bot_token,
        telegram_admin_chat_id,
        bridge_token,
      )
    })
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
  conn: sqlight.Connection,
  bridge_url: String,
  telegram_secret: String,
  telegram_bot_token: String,
  telegram_admin_chat_id: String,
  bridge_token: String,
) -> response.Response(ResponseData) {
  case req.path {
    "/webhook" ->
      proteger_webhook(
        req,
        seguranca_http.cabecalho_bridge,
        bridge_token,
        fn(req) { handle_webhook(req, portas) },
      )
    "/webhook/telegram" ->
      handle_telegram_webhook(req, portas, telegram_secret, telegram_bot_token)
    "/webhook/bridge-event" ->
      proteger_webhook(
        req,
        seguranca_http.cabecalho_bridge,
        bridge_token,
        fn(req) {
          handle_bridge_event(req, telegram_bot_token, telegram_admin_chat_id)
        },
      )
    "/health" -> handle_health(conn, bridge_url, telegram_bot_token)
    _ -> json_response(404, "{\"error\":\"not found\"}")
  }
}

fn proteger_webhook(
  req: Request(Connection),
  cabecalho: String,
  segredo: String,
  handler: fn(Request(Connection)) -> response.Response(ResponseData),
) -> response.Response(ResponseData) {
  case seguranca_http.autorizar_webhook(req, cabecalho, segredo) {
    Ok(_) -> handler(req)
    Error(status) -> json_response(status, "{\"error\":\"request rejected\"}")
  }
}

pub fn handle_health(
  conn: sqlight.Connection,
  bridge_url: String,
  telegram_bot_token: String,
) -> response.Response(ResponseData) {
  let #(sqlite_status, sqlite_ok) = case sqlight.exec("SELECT 1;", conn) {
    Ok(_) -> #("ok", True)
    Error(err) -> #(err.message, False)
  }

  let #(wa_status, wa_connected, wa_logged_in) = case
    whatsmeow_http.checar_status(bridge_url)
  {
    Ok(whatsmeow_http.StatusBridge(conectado, logado)) -> {
      let st = case logado {
        True -> "ok"
        False -> "unauthenticated"
      }
      #(st, conectado, logado)
    }
    Error(_) -> #("unreachable", False, False)
  }

  let telegram_enabled = telegram_bot_token != ""
  let mem_total = metricas.memoria_total_mb()
  let mem_proc = metricas.memoria_processos_mb()
  let proc_count = metricas.contagem_processos()

  let overall_status = case sqlite_ok {
    False -> "error"
    True ->
      case wa_logged_in {
        True -> "ok"
        False -> "degraded"
      }
  }

  let http_code = case sqlite_ok {
    True -> 200
    False -> 503
  }

  let body =
    json.object([
      #("status", json.string(overall_status)),
      #(
        "sqlite",
        json.object([
          #("status", json.string(sqlite_status)),
          #("ok", json.bool(sqlite_ok)),
        ]),
      ),
      #(
        "whatsapp_bridge",
        json.object([
          #("status", json.string(wa_status)),
          #("connected", json.bool(wa_connected)),
          #("logged_in", json.bool(wa_logged_in)),
        ]),
      ),
      #(
        "telegram",
        json.object([
          #("status", json.string("ok")),
          #("enabled", json.bool(telegram_enabled)),
        ]),
      ),
      #(
        "beam",
        json.object([
          #("memoria_total_mb", json.int(mem_total)),
          #("memoria_processos_mb", json.int(mem_proc)),
          #("contagem_processos", json.int(proc_count)),
        ]),
      ),
    ])
    |> json.to_string

  json_response(http_code, body)
}

type BridgeEvento {
  BridgePairingCode(phone: String, code: String)
  BridgeWhatsappDown(motivo: String)
}

fn handle_bridge_event(
  req: Request(Connection),
  bot_token: String,
  admin_chat_id: String,
) -> response.Response(ResponseData) {
  case mist.read_body(req, 1024 * 1024) {
    Error(_) -> json_response(400, "{\"error\":\"failed to read body\"}")
    Ok(req_with_body) -> {
      case parse_bridge_event(req_with_body.body) {
        Error(_) -> json_response(400, "{\"error\":\"invalid payload\"}")
        Ok(evt) -> {
          case bot_token == "" || admin_chat_id == "" {
            True -> Nil
            _ -> {
              case evt {
                BridgePairingCode(phone, code) -> {
                  let texto =
                    "⚠️ *Alerta: WhatsApp desconectado!*\n\n"
                    <> "📱 *Novo código de pareamento para* `+"
                    <> phone
                    <> "`:\n"
                    <> "`"
                    <> code
                    <> "`\n\n"
                    <> "👉 *No WhatsApp do seu celular:*\n"
                    <> "Aparelhos conectados > Conectar com número de telefone > Digite o código acima."
                  let _ =
                    telegram_http.enviar_mensagem(
                      bot_token,
                      admin_chat_id,
                      texto,
                    )
                  Nil
                }
                BridgeWhatsappDown(motivo) -> {
                  let texto =
                    "⚠️ *Alerta: A conexão do WhatsApp caiu!*\n\n"
                    <> "Motivo: "
                    <> motivo
                    <> "\n\n"
                    <> "Para gerar um novo código de pareamento, envie:\n"
                    <> "`/parear <seu_numero>`"
                  let _ =
                    telegram_http.enviar_mensagem(
                      bot_token,
                      admin_chat_id,
                      texto,
                    )
                  Nil
                }
              }
            }
          }
          json_response(200, "{\"ok\":true}")
        }
      }
    }
  }
}

fn parse_bridge_event(body: BitArray) -> Result(BridgeEvento, Nil) {
  use s <- result.try(
    bit_array.to_string(body)
    |> result.map_error(fn(_) { Nil }),
  )
  let decoder = {
    use evento <- decode.field("evento", decode.string)
    use phone <- decode.optional_field("phone", "", decode.string)
    use code <- decode.optional_field("code", "", decode.string)
    use motivo <- decode.optional_field("motivo", "Desconectado", decode.string)
    case evento {
      "pairing_code" -> decode.success(BridgePairingCode(phone, code))
      _ -> decode.success(BridgeWhatsappDown(motivo))
    }
  }
  json.parse(s, decoder)
  |> result.map_error(fn(_) { Nil })
}

fn handle_telegram_webhook(
  req: Request(Connection),
  portas: Portas,
  secret_token: String,
  bot_token: String,
) -> response.Response(ResponseData) {
  proteger_webhook(
    req,
    "x-telegram-bot-api-secret-token",
    secret_token,
    fn(req) { processar_telegram_body(req, portas, bot_token) },
  )
}

fn processar_telegram_body(
  req: Request(Connection),
  portas: Portas,
  bot_token: String,
) -> response.Response(ResponseData) {
  case mist.read_body(req, 1024 * 1024) {
    Error(_) -> json_response(400, "{\"error\":\"failed to read body\"}")
    Ok(req_with_body) ->
      case telegram_webhook.parsear_evento(req_with_body.body) {
        Error(_) ->
          json_response(400, "{\"error\":\"invalid telegram payload\"}")
        Ok(telegram_webhook.EventoIgnorado(_)) ->
          json_response(200, "{\"ok\":true,\"ignored\":true}")
        Ok(evento) -> {
          telegram_poller.despachar_evento(evento, bot_token, portas)
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
      |> result.try(validar_webhook)
  }
}

fn validar_webhook(webhook: Webhook) -> Result(Webhook, Nil) {
  use _ <- result.try(
    case
      seguranca_http.identidade_whatsapp_valida(
        webhook.msg.chat_id,
        webhook.msg.remetente,
      )
    {
      True -> Ok(Nil)
      False -> Error(Nil)
    },
  )
  let arquivo = case webhook.msg.corpo {
    mensagem.Video(caminho_temp: caminho, ..) -> option.Some(caminho)
    _ -> webhook.arquivo
  }
  case arquivo {
    option.None -> Ok(webhook)
    option.Some(caminho) ->
      validar_arquivo(caminho)
      |> result.map(fn(_) { webhook })
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
