import dominio/erro.{type Erro}
import gleam/dynamic/decode
import gleam/result
import portas/grupo_porta.{type GrupoPorta, GrupoPorta}
import sqlight

const schema = "CREATE TABLE IF NOT EXISTS grupos (
  chat_id TEXT PRIMARY KEY,
  nome TEXT NOT NULL,
  last_seen INTEGER NOT NULL
)"

pub fn criar(conn: sqlight.Connection) -> GrupoPorta {
  let _ = sqlight.exec(schema, conn)
  GrupoPorta(
    registrar: fn(chat_id, nome) { registrar(conn, chat_id, nome) },
    listar: fn() { listar(conn) },
  )
}

fn registrar(conn: sqlight.Connection, chat_id: String, nome: String) -> Result(Nil, Erro) {
  sqlight.query(
    "INSERT INTO grupos (chat_id, nome, last_seen) VALUES (?, ?, strftime('%s','now'))
     ON CONFLICT(chat_id) DO UPDATE SET last_seen = excluded.last_seen, nome = excluded.nome",
    on: conn,
    with: [sqlight.text(chat_id), sqlight.text(nome)],
    expecting: decode.dynamic,
  )
  |> result.map(fn(_) { Nil })
  |> result.map_error(fn(e) { erro.ErroBancoDados(e.message) })
}

fn listar(conn: sqlight.Connection) -> Result(List(String), Erro) {
  sqlight.query(
    "SELECT chat_id || ' (' || nome || ')' FROM grupos ORDER BY last_seen DESC",
    on: conn,
    with: [],
    expecting: decode.at([0], decode.string),
  )
  |> result.map_error(fn(e) { erro.ErroBancoDados(e.message) })
}
