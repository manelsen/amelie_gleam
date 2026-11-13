//// Healthcheck: estado do armazenamento, da ponte do WhatsApp, do Telegram e
//// da BEAM, pelas portas.

import gleam/json
import portas/armazenamento_porta.{type ArmazenamentoPorta}
import portas/ponte_porta.{type PontePorta, StatusPonte}
import shell/metricas

/// Healthcheck detalhado, para quem tem o token da ponte. Devolve o código
/// HTTP e o corpo JSON.
pub fn detalhada(
  armazenamento: ArmazenamentoPorta,
  ponte: PontePorta,
  telegram_ativo: Bool,
) -> #(Int, String) {
  let #(sqlite_status, sqlite_ok) = case armazenamento.verificar() {
    Ok(Nil) -> #("ok", True)
    Error(mensagem) -> #(mensagem, False)
  }

  let #(wa_status, wa_connected, wa_logged_in) = case ponte.checar_status() {
    Ok(StatusPonte(conectado, logado)) -> {
      let st = case logado {
        True -> "ok"
        False -> "unauthenticated"
      }
      #(st, conectado, logado)
    }
    Error(_) -> #("unreachable", False, False)
  }

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
          #("enabled", json.bool(telegram_ativo)),
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

  #(http_code, body)
}

/// Healthcheck sem autenticação: só o status agregado. O detalhe (estado do
/// WhatsApp, métricas da BEAM, mensagem de erro do SQLite) exige o mesmo
/// token da ponte, em `x-amelie-bridge-token`.
pub fn publica(
  armazenamento: ArmazenamentoPorta,
  ponte: PontePorta,
) -> #(Int, String) {
  let sqlite_ok = case armazenamento.verificar() {
    Ok(Nil) -> True
    Error(_) -> False
  }
  let wa_logado = case ponte.checar_status() {
    Ok(StatusPonte(_, logado)) -> logado
    Error(_) -> False
  }
  let #(codigo, status) = case sqlite_ok, wa_logado {
    False, _ -> #(503, "error")
    True, True -> #(200, "ok")
    True, False -> #(200, "degraded")
  }
  #(codigo, json.to_string(json.object([#("status", json.string(status))])))
}
