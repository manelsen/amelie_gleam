// Adaptador SQLite para prompts nomeados por chat.

import dominio/erro.{type Erro}
import gleam/dynamic/decode
import gleam/option.{type Option, None, Some}
import gleam/result
import portas/prompt_porta.{type PromptPorta, PromptPorta}
import sqlight

const schema = "CREATE TABLE IF NOT EXISTS prompts (
  chat_id TEXT NOT NULL,
  nome TEXT NOT NULL,
  texto TEXT NOT NULL,
  PRIMARY KEY (chat_id, nome)
)"

pub fn criar(conn: sqlight.Connection) -> PromptPorta {
  let _ = sqlight.exec(schema, conn)
  PromptPorta(
    definir: fn(chat_id, nome, texto) { definir(conn, chat_id, nome, texto) },
    obter: fn(chat_id, nome) { obter(conn, chat_id, nome) },
    listar: fn(chat_id) { listar(conn, chat_id) },
    excluir: fn(chat_id, nome) { excluir(conn, chat_id, nome) },
  )
}

fn definir(
  conn: sqlight.Connection,
  chat_id: String,
  nome: String,
  texto: String,
) -> Result(Nil, Erro) {
  sqlight.query(
    "INSERT INTO prompts (chat_id, nome, texto) VALUES (?, ?, ?)
     ON CONFLICT(chat_id, nome) DO UPDATE SET texto = excluded.texto",
    on: conn,
    with: [sqlight.text(chat_id), sqlight.text(nome), sqlight.text(texto)],
    expecting: decode.dynamic,
  )
  |> result.map(fn(_) { Nil })
  |> result.map_error(fn(e) { erro.ErroBancoDados(e.message) })
}

fn obter(
  conn: sqlight.Connection,
  chat_id: String,
  nome: String,
) -> Result(Option(String), Erro) {
  case
    sqlight.query(
      "SELECT texto FROM prompts WHERE chat_id = ? AND nome = ?",
      on: conn,
      with: [sqlight.text(chat_id), sqlight.text(nome)],
      expecting: decode.at([0], decode.string),
    )
  {
    Ok([texto, ..]) -> Ok(Some(texto))
    Ok([]) -> Ok(None)
    Error(e) -> Error(erro.ErroBancoDados(e.message))
  }
}

fn listar(
  conn: sqlight.Connection,
  chat_id: String,
) -> Result(List(String), Erro) {
  sqlight.query(
    "SELECT nome FROM prompts WHERE chat_id = ? ORDER BY nome",
    on: conn,
    with: [sqlight.text(chat_id)],
    expecting: decode.at([0], decode.string),
  )
  |> result.map_error(fn(e) { erro.ErroBancoDados(e.message) })
}

fn excluir(
  conn: sqlight.Connection,
  chat_id: String,
  nome: String,
) -> Result(Nil, Erro) {
  sqlight.query(
    "DELETE FROM prompts WHERE chat_id = ? AND nome = ?",
    on: conn,
    with: [sqlight.text(chat_id), sqlight.text(nome)],
    expecting: decode.dynamic,
  )
  |> result.map(fn(_) { Nil })
  |> result.map_error(fn(e) { erro.ErroBancoDados(e.message) })
}
