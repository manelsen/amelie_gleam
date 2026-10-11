// adaptadores/video_contexto_sqlite.gleam
// Adaptador SQLite para gerenciar o contexto temporário de vídeos recentes.

import dominio/erro.{type Erro}
import dominio/video_contexto.{type VideoContexto, VideoContexto}
import gleam/dynamic/decode
import gleam/option.{type Option, None, Some}
import gleam/result
import portas/video_contexto_porta.{type VideoContextoPorta, VideoContextoPorta}
import sqlight

const schema = "CREATE TABLE IF NOT EXISTS video_contexto (
  chat_id TEXT PRIMARY KEY,
  uri TEXT NOT NULL,
  perguntas_restantes INTEGER NOT NULL DEFAULT 2,
  criado_em INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
);
CREATE INDEX IF NOT EXISTS idx_video_contexto_criado_em ON video_contexto(criado_em);"

pub fn criar(conn: sqlight.Connection) -> VideoContextoPorta {
  let _ = sqlight.exec(schema, conn)
  VideoContextoPorta(
    obter: fn(chat_id) { obter(conn, chat_id) },
    salvar: fn(ctx) { salvar(conn, ctx) },
    decrementar_perguntas: fn(chat_id) { decrementar_perguntas(conn, chat_id) },
    remover: fn(chat_id) { remover(conn, chat_id) },
    limpar_expirados: fn(antes_de) { limpar_expirados(conn, antes_de) },
  )
}

fn decoder_contexto(chat_id: String) -> decode.Decoder(VideoContexto) {
  use uri <- decode.then(decode.at([0], decode.string))
  use perguntas <- decode.then(decode.at([1], decode.int))
  use criado_em <- decode.then(decode.at([2], decode.int))
  decode.success(VideoContexto(
    chat_id: chat_id,
    uri: uri,
    perguntas_restantes: perguntas,
    criado_em: criado_em,
  ))
}

fn obter(
  conn: sqlight.Connection,
  chat_id: String,
) -> Result(Option(VideoContexto), Erro) {
  let resultado =
    sqlight.query(
      "SELECT uri, perguntas_restantes, criado_em
       FROM video_contexto
       WHERE chat_id = ?
       LIMIT 1",
      on: conn,
      with: [sqlight.text(chat_id)],
      expecting: decoder_contexto(chat_id),
    )
    |> result.map_error(fn(e) { erro.ErroBancoDados(e.message) })

  use linhas <- result.try(resultado)
  case linhas {
    [ctx, ..] -> Ok(Some(ctx))
    [] -> Ok(None)
  }
}

fn salvar(conn: sqlight.Connection, ctx: VideoContexto) -> Result(Nil, Erro) {
  sqlight.query(
    "INSERT INTO video_contexto (chat_id, uri, perguntas_restantes, criado_em)
     VALUES (?, ?, ?, ?)
     ON CONFLICT(chat_id) DO UPDATE SET
       uri = excluded.uri,
       perguntas_restantes = excluded.perguntas_restantes,
       criado_em = excluded.criado_em;",
    on: conn,
    with: [
      sqlight.text(ctx.chat_id),
      sqlight.text(ctx.uri),
      sqlight.int(ctx.perguntas_restantes),
      sqlight.int(ctx.criado_em),
    ],
    expecting: decode.dynamic,
  )
  |> result.map(fn(_) { Nil })
  |> result.map_error(fn(e) { erro.ErroBancoDados(e.message) })
}

fn decrementar_perguntas(
  conn: sqlight.Connection,
  chat_id: String,
) -> Result(Int, Erro) {
  use _ <- result.try(
    sqlight.query(
      "UPDATE video_contexto
       SET perguntas_restantes = MAX(0, perguntas_restantes - 1)
       WHERE chat_id = ?;",
      on: conn,
      with: [sqlight.text(chat_id)],
      expecting: decode.dynamic,
    )
    |> result.map(fn(_) { Nil })
    |> result.map_error(fn(e) { erro.ErroBancoDados(e.message) }),
  )

  let consulta =
    sqlight.query(
      "SELECT perguntas_restantes FROM video_contexto WHERE chat_id = ?;",
      on: conn,
      with: [sqlight.text(chat_id)],
      expecting: decode.at([0], decode.int),
    )
    |> result.map_error(fn(e) { erro.ErroBancoDados(e.message) })

  use linhas <- result.try(consulta)
  case linhas {
    [restantes, ..] -> Ok(restantes)
    [] -> Ok(0)
  }
}

fn remover(
  conn: sqlight.Connection,
  chat_id: String,
) -> Result(Option(String), Erro) {
  let consulta =
    sqlight.query(
      "SELECT uri FROM video_contexto WHERE chat_id = ?;",
      on: conn,
      with: [sqlight.text(chat_id)],
      expecting: decode.at([0], decode.string),
    )
    |> result.map_error(fn(e) { erro.ErroBancoDados(e.message) })

  use linhas <- result.try(consulta)
  let _ =
    sqlight.query(
      "DELETE FROM video_contexto WHERE chat_id = ?;",
      on: conn,
      with: [sqlight.text(chat_id)],
      expecting: decode.dynamic,
    )

  case linhas {
    [uri, ..] -> Ok(Some(uri))
    [] -> Ok(None)
  }
}

fn limpar_expirados(
  conn: sqlight.Connection,
  antes_de: Int,
) -> Result(List(String), Erro) {
  let consulta =
    sqlight.query(
      "SELECT uri FROM video_contexto WHERE criado_em < ?;",
      on: conn,
      with: [sqlight.int(antes_de)],
      expecting: decode.at([0], decode.string),
    )
    |> result.map_error(fn(e) { erro.ErroBancoDados(e.message) })

  use uris <- result.try(consulta)
  let _ =
    sqlight.query(
      "DELETE FROM video_contexto WHERE criado_em < ?;",
      on: conn,
      with: [sqlight.int(antes_de)],
      expecting: decode.dynamic,
    )

  Ok(uris)
}
