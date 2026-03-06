// Adaptador SQLite para histórico de conversa por chat.
// Implementa HistoricoPorta usando sqlight.

import dominio/erro.{type Erro}
import dominio/mensagem.{TurnoAssistente, TurnoUsuario, type Turno}
import gleam/dynamic/decode
import gleam/result
import portas/historico_porta.{type HistoricoPorta, HistoricoPorta}
import sqlight

const schema = "CREATE TABLE IF NOT EXISTS historico (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  chat_id TEXT NOT NULL,
  papel TEXT NOT NULL,
  conteudo TEXT NOT NULL,
  criado_em INTEGER NOT NULL DEFAULT (unixepoch())
)"

const schema_idx = "CREATE INDEX IF NOT EXISTS idx_historico_chat
  ON historico (chat_id, id)"

pub fn criar(conn: sqlight.Connection) -> HistoricoPorta {
  let _ = sqlight.exec(schema, conn)
  let _ = sqlight.exec(schema_idx, conn)
  HistoricoPorta(
    obter: fn(chat_id) { obter(conn, chat_id) },
    adicionar: fn(chat_id, turno) { adicionar(conn, chat_id, turno) },
    limpar: fn(chat_id) { limpar(conn, chat_id) },
  )
}

fn obter(conn: sqlight.Connection, chat_id: String) -> Result(List(Turno), Erro) {
  let sql =
    "SELECT papel, conteudo FROM historico
     WHERE chat_id = ?
     ORDER BY id ASC"

  sqlight.query(sql, on: conn, with: [sqlight.text(chat_id)], expecting: turno_decoder())
  |> result.map_error(fn(e) { erro.ErroBancoDados(e.message) })
}

fn turno_decoder() -> decode.Decoder(Turno) {
  use papel <- decode.then(decode.at([0], decode.string))
  use conteudo <- decode.then(decode.at([1], decode.string))
  case papel {
    "usuario" -> decode.success(TurnoUsuario(conteudo))
    _ -> decode.success(TurnoAssistente(conteudo))
  }
}

fn adicionar(
  conn: sqlight.Connection,
  chat_id: String,
  turno: Turno,
) -> Result(Nil, Erro) {
  let sql =
    "INSERT INTO historico (chat_id, papel, conteudo) VALUES (?, ?, ?)"
  let #(papel, conteudo) = case turno {
    TurnoUsuario(c) -> #("usuario", c)
    TurnoAssistente(c) -> #("assistente", c)
  }

  sqlight.query(
    sql,
    on: conn,
    with: [sqlight.text(chat_id), sqlight.text(papel), sqlight.text(conteudo)],
    expecting: decode.dynamic,
  )
  |> result.map(fn(_) { Nil })
  |> result.map_error(fn(e) { erro.ErroBancoDados(e.message) })
}

fn limpar(conn: sqlight.Connection, chat_id: String) -> Result(Nil, Erro) {
  let sql = "DELETE FROM historico WHERE chat_id = ?"
  sqlight.query(sql, on: conn, with: [sqlight.text(chat_id)], expecting: decode.dynamic)
  |> result.map(fn(_) { Nil })
  |> result.map_error(fn(e) { erro.ErroBancoDados(e.message) })
}
