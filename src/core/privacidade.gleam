// Privacidade em log. Puro — não faz IO.

import gleam/list
import gleam/string

/// Mascara o identificador de um usuário para log: telefone, JID do WhatsApp
/// (com ou sem agente/dispositivo), ID de grupo ou ID do Telegram (`tg:`).
/// Mantém os 4 primeiros e os 4 últimos caracteres do usuário e o servidor,
/// para correlacionar linhas de log sem expor o identificador inteiro.
/// Mesma regra de `maskID` na ponte Go, mais o prefixo `tg:`.
pub fn mascarar_id(id: String) -> String {
  case string.starts_with(id, "tg:") {
    True -> "tg:" <> mascarar_jid(string.drop_start(id, 3))
    False -> mascarar_jid(id)
  }
}

fn mascarar_jid(id: String) -> String {
  let #(local, sufixo_servidor) = case string.split_once(id, "@") {
    Ok(#(local, servidor)) -> #(local, "@" <> servidor)
    Error(Nil) -> #(id, "")
  }
  let #(usuario, resto) =
    local
    |> string.to_graphemes
    |> list.split_while(fn(g) { g != "." && g != ":" })
  let usuario = string.concat(usuario)
  let resto = string.concat(resto)
  let tamanho = string.length(usuario)
  let mascarado = case tamanho > 8 {
    True ->
      string.slice(usuario, 0, 4)
      <> "****"
      <> string.slice(usuario, tamanho - 4, 4)
    False -> "****"
  }
  mascarado <> resto <> sufixo_servidor
}
