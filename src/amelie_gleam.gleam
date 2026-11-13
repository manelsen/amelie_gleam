import adaptadores/config_sqlite
import adaptadores/gemini_http
import adaptadores/grupo_sqlite
import adaptadores/historico_sqlite
import adaptadores/openrouter_http
import adaptadores/prompt_sqlite
import adaptadores/roteador_mensageiro
import adaptadores/spammer_sqlite
import adaptadores/telegram_http
import adaptadores/telegram_webhook
import adaptadores/transacao_sqlite
import adaptadores/usuario_sqlite
import adaptadores/video_contexto_sqlite
import adaptadores/whatsmeow_http
import adaptadores/whatsmeow_webhook
import dominio/id_chat.{type IdChat}
import dominio/provedores_config
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http/request.{type Request}
import gleam/http/response
import gleam/int
import gleam/json
import gleam/option.{type Option}
import gleam/result
import gleam/string
import mist.{type Connection, type ResponseData}
import portas/ponte_porta.{
  type EventoPonte, CodigoPareamentoGerado, WhatsappCaiu, WhatsappVoltou,
}
import portas/telegram_porta
import shell/arvore_supervisao
import shell/despachante_ia
import shell/fila_atrasadas.{type FilaAtrasadas}
import shell/fila_offline
import shell/ia_resiliente
import shell/metricas
import shell/receptor_telegram
import shell/receptor_whatsapp
import shell/seguranca_http
import shell/sistema
import shell/tratador/base.{type Portas, Portas}
import simplifile
import sqlight

import dot_env
import logging

// ---------------------------------------------------------------------------
// FFI — variáveis de ambiente
// ---------------------------------------------------------------------------

@external(erlang, "amelie_gleam_ffi", "ensure_applications_started")
fn garantir_aplicacoes_iniciadas() -> Nil

pub fn main() {
  dot_env.new()
  |> dot_env.load

  logging.configure()
  garantir_aplicacoes_iniciadas()

  let bridge_token = seguranca_http.token_ponte()
  let assert True = string.byte_size(bridge_token) >= 32
    as "Defina BRIDGE_TOKEN com pelo menos 32 caracteres aleatórios"

  let gemini_api_key = sistema.ler_env_ou("GEMINI_API_KEY", "")
  let openrouter_api_key = sistema.ler_env_ou("OPENROUTER_API_KEY", "")
  let telegram_bot_token = sistema.ler_env_ou("TELEGRAM_BOT_TOKEN", "")
  let telegram_secret_token = sistema.ler_env_ou("TELEGRAM_SECRET_TOKEN", "")
  let telegram_admin_chat_id = sistema.admin_chat_id()

  let url_ponte = sistema.url_ponte()
  let db_path = sistema.ler_env_ou("DB_PATH", "./db/amelie.sqlite")
  let port_str = sistema.ler_env_ou("PORT", "4000")
  let offline_retry_interval_str =
    sistema.ler_env_ou("OFFLINE_RETRY_INTERVAL_MS", "30000")
  let port =
    int.parse(port_str)
    |> result.unwrap(or: 4000)
  let offline_retry_interval_ms =
    int.parse(offline_retry_interval_str)
    |> result.unwrap(or: 30_000)
  let manutencao_intervalo_str =
    sistema.ler_env_ou("MANUTENCAO_INTERVALO_MS", "3600000")
  let manutencao_intervalo_ms =
    int.parse(manutencao_intervalo_str)
    |> result.unwrap(or: 3_600_000)

  let provedores_config =
    simplifile.read("./config/providers.yaml")
    |> result.replace_error(Nil)
    |> result.try(fn(texto) {
      provedores_config.parsear(texto) |> result.replace_error(Nil)
    })
    |> result.unwrap(provedores_config.padrao())

  use conn <- sqlight.with_connection(db_path)

  let _ = sqlight.exec("PRAGMA journal_mode = WAL;", conn)
  let _ = sqlight.exec("PRAGMA busy_timeout = 5000;", conn)
  let _ = sqlight.exec("PRAGMA synchronous = NORMAL;", conn)

  let config_p = config_sqlite.criar(conn)
  let historico_p = historico_sqlite.criar(conn)
  let prompts_p = prompt_sqlite.criar(conn)
  let usuarios_p = usuario_sqlite.criar(conn)
  let grupos_p = grupo_sqlite.criar(conn)
  let transacoes_p = transacao_sqlite.criar(conn)
  let spammers_p = spammer_sqlite.criar(conn)
  let video_contexto_p = video_contexto_sqlite.criar(conn)
  let conexao_ponte =
    whatsmeow_http.Conexao(url: url_ponte, token: bridge_token)
  let whatsapp = whatsmeow_http.criar(conexao_ponte)
  let telegram = telegram_http.criar(telegram_bot_token)
  let mensageiro = roteador_mensageiro.criar(whatsapp, telegram)
  let ponte = whatsmeow_http.criar_ponte(conexao_ponte)

  let #(_supervisor, procs) =
    arvore_supervisao.iniciar_completo(
      transacoes_p,
      mensageiro,
      ponte,
      manutencao_intervalo_ms,
      telegram_admin_chat_id,
    )
    |> result.lazy_unwrap(fn() {
      panic as "falha ao iniciar árvore de supervisão de processos de suporte"
    })

  let gemini_ia =
    gemini_http.criar(gemini_api_key)
    |> ia_resiliente.envolver(procs.cb_gemini, procs.cache_gemini)
  let openrouter_ia =
    openrouter_http.criar(openrouter_api_key)
    |> ia_resiliente.envolver(procs.cb_openrouter, procs.cache_openrouter)
  let despachante_ia =
    despachante_ia.DespachanteIA(gemini: gemini_ia, openrouter: openrouter_ia)

  let _ =
    fila_offline.agendar_processamento(
      procs.fila_offline,
      offline_retry_interval_ms,
    )

  let portas =
    Portas(
      mensageiro: mensageiro,
      despachante_ia: despachante_ia,
      config: config_p,
      historico: historico_p,
      fila: procs.fila,
      prompts: prompts_p,
      metricas: procs.metricas,
      usuarios: usuarios_p,
      grupos: grupos_p,
      transacoes: transacoes_p,
      provedores_config: provedores_config,
      anti_spam: procs.anti_spam,
      spammers: spammers_p,
      video_contexto: video_contexto_p,
      ponte: ponte,
    )

  case string.trim(telegram_bot_token) {
    "" -> Nil
    token ->
      receptor_telegram.iniciar(
        telegram_http.criar_api(token),
        portas,
        procs.fila_atrasadas,
      )
  }

  let assert Ok(_) =
    mist.new(fn(req) {
      tratar_requisicao(
        req,
        portas,
        procs.fila_atrasadas,
        conn,
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

fn tratar_requisicao(
  req: Request(Connection),
  portas: Portas,
  atrasadas: FilaAtrasadas,
  conn: sqlight.Connection,
  telegram_secret: String,
  telegram_bot_token: String,
  telegram_admin_chat_id: Option(IdChat),
  bridge_token: String,
) -> response.Response(ResponseData) {
  case req.path {
    "/webhook" ->
      proteger_webhook(req, ponte_porta.cabecalho_token, bridge_token, fn(req) {
        tratar_webhook(req, portas, atrasadas)
      })
    "/webhook/telegram" ->
      tratar_webhook_telegram(
        req,
        portas,
        atrasadas,
        telegram_secret,
        telegram_bot_token,
      )
    "/webhook/bridge-event" ->
      proteger_webhook(req, ponte_porta.cabecalho_token, bridge_token, fn(req) {
        tratar_evento_ponte(req, telegram_bot_token, telegram_admin_chat_id)
      })
    "/health" ->
      case
        seguranca_http.autorizado(
          req,
          ponte_porta.cabecalho_token,
          bridge_token,
        )
      {
        True -> tratar_saude(conn, portas.ponte, telegram_bot_token)
        False -> tratar_saude_publica(conn, portas.ponte)
      }
    _ -> resposta_json(404, "{\"error\":\"not found\"}")
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
    Error(status) -> resposta_json(status, "{\"error\":\"request rejected\"}")
  }
}

pub fn tratar_saude(
  conn: sqlight.Connection,
  ponte: ponte_porta.PontePorta,
  telegram_bot_token: String,
) -> response.Response(ResponseData) {
  let #(sqlite_status, sqlite_ok) = case sqlight.exec("SELECT 1;", conn) {
    Ok(_) -> #("ok", True)
    Error(err) -> #(err.message, False)
  }

  let #(wa_status, wa_connected, wa_logged_in) = case ponte.checar_status() {
    Ok(ponte_porta.StatusPonte(conectado, logado)) -> {
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

  resposta_json(http_code, body)
}

/// Healthcheck sem autenticação: só o status agregado. O detalhe (estado do
/// WhatsApp, métricas da BEAM, mensagem de erro do SQLite) exige o mesmo
/// token da ponte, em `x-amelie-bridge-token`.
pub fn tratar_saude_publica(
  conn: sqlight.Connection,
  ponte: ponte_porta.PontePorta,
) -> response.Response(ResponseData) {
  let sqlite_ok = case sqlight.exec("SELECT 1;", conn) {
    Ok(_) -> True
    Error(_) -> False
  }
  let wa_logado = case ponte.checar_status() {
    Ok(ponte_porta.StatusPonte(_, logado)) -> logado
    Error(_) -> False
  }
  let #(codigo, status) = case sqlite_ok, wa_logado {
    False, _ -> #(503, "error")
    True, True -> #(200, "ok")
    True, False -> #(200, "degraded")
  }
  resposta_json(codigo, "{\"status\":\"" <> status <> "\"}")
}

fn tratar_evento_ponte(
  req: Request(Connection),
  bot_token: String,
  admin_chat_id: Option(IdChat),
) -> response.Response(ResponseData) {
  case mist.read_body(req, 1024 * 1024) {
    Error(_) -> resposta_json(400, "{\"error\":\"failed to read body\"}")
    Ok(req_with_body) -> {
      case whatsmeow_webhook.decodificar_evento(req_with_body.body) {
        Error(_) -> resposta_json(400, "{\"error\":\"invalid payload\"}")
        Ok(evt) ->
          case bot_token, admin_chat_id {
            "", _ | _, option.None -> resposta_json(200, "{\"ok\":true}")
            _, option.Some(admin_chat_id) ->
              // Falha no Telegram vira 502: a ponte tenta de novo.
              case
                telegram_http.enviar_mensagem(
                  bot_token,
                  admin_chat_id,
                  texto_evento_ponte(evt),
                )
              {
                Ok(Nil) -> resposta_json(200, "{\"ok\":true}")
                Error(_) ->
                  resposta_json(502, "{\"error\":\"telegram send failed\"}")
              }
          }
      }
    }
  }
}

fn texto_evento_ponte(evt: EventoPonte) -> String {
  case evt {
    CodigoPareamentoGerado(phone, code) ->
      "⚠️ *Alerta: WhatsApp desconectado!*\n\n"
      <> "📱 *Novo código de pareamento para* `+"
      <> phone
      <> "`:\n"
      <> "`"
      <> code
      <> "`\n\n"
      <> "👉 *No WhatsApp do seu celular:*\n"
      <> "Aparelhos conectados > Conectar com número de telefone > Digite o código acima.\n\n"
      <> "⏳ Vale por cerca de 2 minutos. Se expirar, mando outro, e os anteriores deixam de valer."
    WhatsappCaiu(motivo) ->
      "⚠️ *Alerta: A conexão do WhatsApp caiu!*\n\n"
      <> "Motivo: "
      <> motivo
      <> "\n\n"
      <> "Para gerar um novo código de pareamento, envie:\n"
      <> "`/parear <seu_numero>`"
    WhatsappVoltou ->
      "✅ *A Amélie voltou!*\n\n"
      <> "O WhatsApp está conectado e atendendo de novo."
  }
}

fn tratar_webhook_telegram(
  req: Request(Connection),
  portas: Portas,
  atrasadas: FilaAtrasadas,
  secret_token: String,
  bot_token: String,
) -> response.Response(ResponseData) {
  proteger_webhook(
    req,
    "x-telegram-bot-api-secret-token",
    secret_token,
    fn(req) { processar_corpo_telegram(req, portas, atrasadas, bot_token) },
  )
}

fn processar_corpo_telegram(
  req: Request(Connection),
  portas: Portas,
  atrasadas: FilaAtrasadas,
  bot_token: String,
) -> response.Response(ResponseData) {
  case mist.read_body(req, 1024 * 1024) {
    Error(_) -> resposta_json(400, "{\"error\":\"failed to read body\"}")
    Ok(req_with_body) ->
      case telegram_webhook.parsear_evento(req_with_body.body) {
        Error(_) ->
          resposta_json(400, "{\"error\":\"invalid telegram payload\"}")
        Ok(telegram_porta.EventoIgnorado(_)) ->
          resposta_json(200, "{\"ok\":true,\"ignored\":true}")
        Ok(evento) -> {
          receptor_telegram.despachar_evento(
            evento,
            telegram_http.criar_api(bot_token),
            portas,
            atrasadas,
          )
          resposta_json(200, "{\"ok\":true}")
        }
      }
  }
}

fn tratar_webhook(
  req: Request(Connection),
  portas: Portas,
  atrasadas: FilaAtrasadas,
) -> response.Response(ResponseData) {
  case mist.read_body(req, 20 * 1024 * 1024) {
    Error(_) -> resposta_json(400, "{\"error\":\"failed to read body\"}")
    Ok(req_with_body) ->
      case whatsmeow_webhook.decodificar_webhook(req_with_body.body) {
        Error(_) -> resposta_json(400, "{\"error\":\"invalid payload\"}")
        Ok(webhook) -> {
          receptor_whatsapp.despachar(webhook, portas, atrasadas)
          resposta_json(202, "{\"ok\":true}")
        }
      }
  }
}

fn resposta_json(status: Int, body: String) -> response.Response(ResponseData) {
  response.new(status)
  |> response.set_header("content-type", "application/json")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(body)))
}
