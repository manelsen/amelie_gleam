import gleam/http
import gleam/http/request.{type Request}
import gleam/string
import shell/sistema

pub const cabecalho_bridge = "x-amelie-bridge-token"

pub fn token_ponte() -> String {
  sistema.ler_env_ou("BRIDGE_TOKEN", "")
}

pub fn autenticar_ponte(req: Request(a)) -> Request(a) {
  request.set_header(req, cabecalho_bridge, token_ponte())
}

/// O webhook fica fechado se o segredo não foi configurado.
pub fn autorizado(req: Request(a), cabecalho: String, segredo: String) -> Bool {
  case segredo, request.get_header(req, cabecalho) {
    "", _ -> False
    _, Ok(token) -> comparar_tokens(token, segredo)
    _, _ -> False
  }
}

pub fn autorizar_webhook(
  req: Request(a),
  cabecalho: String,
  segredo: String,
) -> Result(Nil, Int) {
  case autorizado(req, cabecalho, segredo) {
    False -> Error(401)
    True ->
      case req.method {
        http.Post -> Ok(Nil)
        _ -> Error(405)
      }
  }
}

pub fn identidade_whatsapp_valida(chat_id: String, remetente: String) -> Bool {
  !string.starts_with(chat_id, "tg:")
  && !string.starts_with(remetente, "tg:")
  && string.contains(chat_id, "@")
  && string.contains(remetente, "@")
}

@external(erlang, "amelie_gleam_ffi", "constant_time_equal")
fn comparar_tokens(a: String, b: String) -> Bool
