import dominio/erro.{type Erro}
import dominio/transacao as t
import gleam/dynamic/decode
import gleam/option.{Some}
import gleam/result
import portas/transacao_porta
import sqlight

const schema = "CREATE TABLE IF NOT EXISTS transacoes (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  chat_id TEXT NOT NULL,
  remetente TEXT NOT NULL,
  tipo TEXT NOT NULL,
  conteudo TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'pendente',
  criado_em INTEGER NOT NULL DEFAULT (unixepoch()),
  atualizado_em INTEGER,
  tentativas INTEGER NOT NULL DEFAULT 0,
  erro TEXT
)"

const schema_idx = "CREATE INDEX IF NOT EXISTS idx_transacoes_chat_status
  ON transacoes (chat_id, status)"

const schema_idx_pendentes = "CREATE INDEX IF NOT EXISTS idx_transacoes_pendentes
  ON transacoes (status, tentativas) WHERE status != 'entregue' AND status != 'descartada'"

pub fn criar(conn: sqlight.Connection) -> transacao_porta.TransacaoPorta {
  let _ = sqlight.exec(schema, conn)
  let _ = sqlight.exec(schema_idx, conn)
  let _ = sqlight.exec(schema_idx_pendentes, conn)
  transacao_porta.TransacaoPorta(
    registrar: fn(tx) { registrar(conn, tx) },
    atualizar_status: fn(id, status) { atualizar_status(conn, id, status) },
    atualizar_erro: fn(id, erro_msg, tentativas) {
      atualizar_erro(conn, id, erro_msg, tentativas)
    },
    obter_pendentes: fn() { obter_pendentes(conn) },
    obter_por_chat: fn(chat_id) { obter_por_chat(conn, chat_id) },
    marcar_entregue: fn(id) { marcar_entregue(conn, id) },
    limpar_antigas: fn() { limpar_antigas(conn) },
  )
}

fn registrar(
  conn: sqlight.Connection,
  tx: t.Transacao,
) -> Result(t.Transacao, Erro) {
  let sql =
    "INSERT INTO transacoes (chat_id, remetente, tipo, conteudo, status, tentativas)
     VALUES (?, ?, ?, ?, ?, ?)"

  let _ =
    sqlight.query(
      sql,
      on: conn,
      with: [
        sqlight.text(tx.chat_id),
        sqlight.text(tx.remetente),
        sqlight.text(tx.tipo),
        sqlight.text(tx.conteudo),
        sqlight.text(t.status_para_string(tx.status)),
        sqlight.int(tx.tentativas),
      ],
      expecting: decode.dynamic,
    )
    |> result.map_error(fn(e) { erro.ErroBancoDados(e.message) })

  sqlight.query(
    "SELECT last_insert_rowid() as id",
    on: conn,
    with: [],
    expecting: decode.at([0], decode.int),
  )
  |> result.map_error(fn(e) { erro.ErroBancoDados(e.message) })
  |> result.map(fn(ids) {
    case ids {
      [id, ..] ->
        t.Transacao(
          id: Some(id),
          chat_id: tx.chat_id,
          remetente: tx.remetente,
          tipo: tx.tipo,
          conteudo: tx.conteudo,
          status: tx.status,
          criado_em: tx.criado_em,
          atualizado_em: tx.atualizado_em,
          tentativas: tx.tentativas,
          erro: tx.erro,
        )
      _ -> tx
    }
  })
}

fn atualizar_status(
  conn: sqlight.Connection,
  id: Int,
  status: t.StatusTransacao,
) -> Result(Nil, Erro) {
  let sql =
    "UPDATE transacoes 
     SET status = ?, atualizado_em = unixepoch() 
     WHERE id = ?"

  sqlight.query(
    sql,
    on: conn,
    with: [
      sqlight.text(t.status_para_string(status)),
      sqlight.int(id),
    ],
    expecting: decode.dynamic,
  )
  |> result.map(fn(_) { Nil })
  |> result.map_error(fn(e) { erro.ErroBancoDados(e.message) })
}

fn atualizar_erro(
  conn: sqlight.Connection,
  id: Int,
  erro_msg: String,
  tentativas: Int,
) -> Result(Nil, Erro) {
  let sql =
    "UPDATE transacoes 
     SET status = 'falha', erro = ?, tentativas = ?, atualizado_em = unixepoch() 
     WHERE id = ?"

  sqlight.query(
    sql,
    on: conn,
    with: [sqlight.text(erro_msg), sqlight.int(tentativas), sqlight.int(id)],
    expecting: decode.dynamic,
  )
  |> result.map(fn(_) { Nil })
  |> result.map_error(fn(e) { erro.ErroBancoDados(e.message) })
}

fn obter_pendentes(conn: sqlight.Connection) -> Result(List(t.Transacao), Erro) {
  let sql =
    "SELECT id, chat_id, remetente, tipo, conteudo, status, criado_em, atualizado_em, tentativas, erro
     FROM transacoes 
     WHERE status != 'entregue' AND status != 'descartada'
     ORDER BY criado_em ASC"

  sqlight.query(sql, on: conn, with: [], expecting: transacao_decoder())
  |> result.map_error(fn(e) { erro.ErroBancoDados(e.message) })
}

fn obter_por_chat(
  conn: sqlight.Connection,
  chat_id: String,
) -> Result(List(t.Transacao), Erro) {
  let sql =
    "SELECT id, chat_id, remetente, tipo, conteudo, status, criado_em, atualizado_em, tentativas, erro
     FROM transacoes 
     WHERE chat_id = ?
     ORDER BY criado_em DESC
     LIMIT 50"

  sqlight.query(
    sql,
    on: conn,
    with: [sqlight.text(chat_id)],
    expecting: transacao_decoder(),
  )
  |> result.map_error(fn(e) { erro.ErroBancoDados(e.message) })
}

fn marcar_entregue(conn: sqlight.Connection, id: Int) -> Result(Nil, Erro) {
  let sql =
    "UPDATE transacoes 
     SET status = 'entregue', atualizado_em = unixepoch() 
     WHERE id = ?"

  sqlight.query(
    sql,
    on: conn,
    with: [sqlight.int(id)],
    expecting: decode.dynamic,
  )
  |> result.map(fn(_) { Nil })
  |> result.map_error(fn(e) { erro.ErroBancoDados(e.message) })
}

// Remove transações entregues ou descartadas com mais de 7 dias.
// Retorna o número de linhas deletadas.
// Remove transações entregues ou descartadas com mais de 7 dias.
fn limpar_antigas(conn: sqlight.Connection) -> Result(Nil, Erro) {
  let sql =
    "DELETE FROM transacoes
     WHERE status IN ('entregue', 'descartada')
       AND criado_em < unixepoch() - 7 * 24 * 60 * 60"

  sqlight.query(sql, on: conn, with: [], expecting: decode.dynamic)
  |> result.map(fn(_) { Nil })
  |> result.map_error(fn(e) { erro.ErroBancoDados(e.message) })
}

fn transacao_decoder() -> decode.Decoder(t.Transacao) {
  use id <- decode.then(decode.at([0], decode.optional(decode.int)))
  use chat_id <- decode.then(decode.at([1], decode.string))
  use remetente <- decode.then(decode.at([2], decode.string))
  use tipo <- decode.then(decode.at([3], decode.string))
  use conteudo <- decode.then(decode.at([4], decode.string))
  use status_str <- decode.then(decode.at([5], decode.string))
  use criado_em <- decode.then(decode.at([6], decode.int))
  use atualizado_em <- decode.then(decode.at([7], decode.optional(decode.int)))
  use tentativas <- decode.then(decode.at([8], decode.int))
  use erro <- decode.then(decode.at([9], decode.optional(decode.string)))
  decode.success(t.Transacao(
    id: id,
    chat_id: chat_id,
    remetente: remetente,
    tipo: tipo,
    conteudo: conteudo,
    status: t.string_para_status(status_str),
    criado_em: criado_em,
    atualizado_em: atualizado_em,
    tentativas: tentativas,
    erro: erro,
  ))
}
