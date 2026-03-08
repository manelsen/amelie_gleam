// Adaptador SQLite para rastreamento de usuários.

import dominio/erro.{type Erro}
import gleam/dynamic/decode
import gleam/result
import portas/usuario_porta.{type UsuarioPorta, UsuarioPorta}
import sqlight

const schema = "CREATE TABLE IF NOT EXISTS usuarios (
  chat_id TEXT PRIMARY KEY,
  last_seen INTEGER NOT NULL
)"

pub fn criar(conn: sqlight.Connection) -> UsuarioPorta {
  let _ = sqlight.exec(schema, conn)
  UsuarioPorta(
    registrar: fn(chat_id) { registrar(conn, chat_id) },
    contar: fn() { contar(conn) },
    listar: fn() { listar(conn) },
  )
}

fn registrar(conn: sqlight.Connection, chat_id: String) -> Result(Nil, Erro) {
  sqlight.query(
    "INSERT INTO usuarios (chat_id, last_seen) VALUES (?, strftime('%s','now'))
     ON CONFLICT(chat_id) DO UPDATE SET last_seen = excluded.last_seen",
    on: conn,
    with: [sqlight.text(chat_id)],
    expecting: decode.dynamic,
  )
  |> result.map(fn(_) { Nil })
  |> result.map_error(fn(e) { erro.ErroBancoDados(e.message) })
}

fn contar(conn: sqlight.Connection) -> Result(Int, Erro) {
  case
    sqlight.query(
      "SELECT COUNT(*) FROM usuarios",
      on: conn,
      with: [],
      expecting: decode.at([0], decode.int),
    )
  {
    Ok([count, ..]) -> Ok(count)
    _ -> Ok(0)
  }
}

fn listar(conn: sqlight.Connection) -> Result(List(String), Erro) {
  sqlight.query(
    "SELECT chat_id FROM usuarios ORDER BY last_seen DESC",
    on: conn,
    with: [],
    expecting: decode.at([0], decode.string),
  )
  |> result.map_error(fn(e) { erro.ErroBancoDados(e.message) })
}
