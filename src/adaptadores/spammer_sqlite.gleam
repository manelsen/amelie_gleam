// adaptadores/spammer_sqlite.gleam
// Adaptador SQLite para auditoria persistente de incidentes de spam e rate limit.

import dominio/erro.{type Erro}
import dominio/spammer.{
  type IncidenteSpam, type ResumoSpammer, IncidenteSpam, ResumoSpammer,
}
import gleam/dynamic/decode
import gleam/result
import portas/spammer_porta.{type SpammerPorta, SpammerPorta}
import sqlight

const schema = "CREATE TABLE IF NOT EXISTS incidentes_spam (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  chat_id TEXT NOT NULL,
  remetente TEXT NOT NULL,
  telefone TEXT NOT NULL,
  motivo TEXT NOT NULL,
  strike INTEGER NOT NULL,
  criado_em INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
);
CREATE INDEX IF NOT EXISTS idx_incidentes_spam_telefone ON incidentes_spam(telefone);
CREATE INDEX IF NOT EXISTS idx_incidentes_spam_criado_em ON incidentes_spam(criado_em);"

pub fn criar(conn: sqlight.Connection) -> SpammerPorta {
  let _ = sqlight.exec(schema, conn)
  SpammerPorta(
    registrar: fn(chat_id, remetente, telefone, motivo, strike) {
      registrar(conn, chat_id, remetente, telefone, motivo, strike)
    },
    listar_recentes: fn(limite) { listar_recentes(conn, limite) },
    listar_top: fn(limite) { listar_top(conn, limite) },
    contar: fn() { contar(conn) },
  )
}

fn registrar(
  conn: sqlight.Connection,
  chat_id: String,
  remetente: String,
  telefone: String,
  motivo: String,
  strike: Int,
) -> Result(Nil, Erro) {
  sqlight.query(
    "INSERT INTO incidentes_spam (chat_id, remetente, telefone, motivo, strike, criado_em)
     VALUES (?, ?, ?, ?, ?, strftime('%s','now'))",
    on: conn,
    with: [
      sqlight.text(chat_id),
      sqlight.text(remetente),
      sqlight.text(telefone),
      sqlight.text(motivo),
      sqlight.int(strike),
    ],
    expecting: decode.dynamic,
  )
  |> result.map(fn(_) { Nil })
  |> result.map_error(fn(e) { erro.ErroBancoDados(e.message) })
}

fn listar_recentes(
  conn: sqlight.Connection,
  limite: Int,
) -> Result(List(IncidenteSpam), Erro) {
  sqlight.query(
    "SELECT id, chat_id, remetente, telefone, motivo, strike, criado_em
     FROM incidentes_spam
     ORDER BY criado_em DESC, id DESC
     LIMIT ?",
    on: conn,
    with: [sqlight.int(limite)],
    expecting: decoder_incidente(),
  )
  |> result.map_error(fn(e) { erro.ErroBancoDados(e.message) })
}

fn listar_top(
  conn: sqlight.Connection,
  limite: Int,
) -> Result(List(ResumoSpammer), Erro) {
  sqlight.query(
    "SELECT telefone, COUNT(*) as total, MAX(strike) as ultimo_strike, MAX(criado_em) as ultimo_em
     FROM incidentes_spam
     GROUP BY telefone
     ORDER BY total DESC, ultimo_em DESC
     LIMIT ?",
    on: conn,
    with: [sqlight.int(limite)],
    expecting: decoder_resumo(),
  )
  |> result.map_error(fn(e) { erro.ErroBancoDados(e.message) })
}

fn contar(conn: sqlight.Connection) -> Result(Int, Erro) {
  case
    sqlight.query(
      "SELECT COUNT(*) FROM incidentes_spam",
      on: conn,
      with: [],
      expecting: decode.at([0], decode.int),
    )
  {
    Ok([count, ..]) -> Ok(count)
    _ -> Ok(0)
  }
}

fn decoder_incidente() -> decode.Decoder(IncidenteSpam) {
  use id <- decode.then(decode.at([0], decode.int))
  use chat_id <- decode.then(decode.at([1], decode.string))
  use remetente <- decode.then(decode.at([2], decode.string))
  use telefone <- decode.then(decode.at([3], decode.string))
  use motivo <- decode.then(decode.at([4], decode.string))
  use strike <- decode.then(decode.at([5], decode.int))
  use criado_em <- decode.then(decode.at([6], decode.int))
  decode.success(IncidenteSpam(
    id: id,
    chat_id: chat_id,
    remetente: remetente,
    telefone: telefone,
    motivo: motivo,
    strike: strike,
    criado_em: criado_em,
  ))
}

fn decoder_resumo() -> decode.Decoder(ResumoSpammer) {
  use telefone <- decode.then(decode.at([0], decode.string))
  use total <- decode.then(decode.at([1], decode.int))
  use ultimo_strike <- decode.then(decode.at([2], decode.int))
  use ultimo_em <- decode.then(decode.at([3], decode.int))
  decode.success(ResumoSpammer(
    telefone: telefone,
    total_incidentes: total,
    ultimo_strike: ultimo_strike,
    ultimo_incidente_em: ultimo_em,
  ))
}
