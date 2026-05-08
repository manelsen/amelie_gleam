// Adaptador SQLite para configuração por chat.

import dominio/config.{type Config, Config}
import dominio/erro.{type Erro}
import gleam/dynamic/decode
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import portas/config_porta.{type ConfigPorta, ConfigPorta}
import sqlight

const schema = "CREATE TABLE IF NOT EXISTS configs (
  chat_id TEXT PRIMARY KEY,
  provedor TEXT NOT NULL DEFAULT 'gemini',
  modelo TEXT NOT NULL DEFAULT 'gemini-2.5-flash-lite',
  historico_max INTEGER NOT NULL DEFAULT 50,
  prompt_sistema TEXT NOT NULL DEFAULT '',
  audio_ativo INTEGER NOT NULL DEFAULT 1,
  imagem_ativo INTEGER NOT NULL DEFAULT 1,
  video_ativo INTEGER NOT NULL DEFAULT 1,
  doc_ativo INTEGER NOT NULL DEFAULT 1,
  legenda_ativo INTEGER NOT NULL DEFAULT 0,
  idioma TEXT NOT NULL DEFAULT 'pt-BR',
  modo_descricao TEXT NOT NULL DEFAULT 'curto'
)"

pub fn criar(conn: sqlight.Connection) -> ConfigPorta {
  let _ = sqlight.exec(schema, conn)
  // Migração: reverter prompts customizados e reativar áudio desligado pelo antigo .cego
  let _ = sqlight.exec("UPDATE configs SET prompt_sistema = '', audio_ativo = 1 WHERE prompt_sistema != ''", conn)
  let _ = sqlight.exec("UPDATE configs SET video_ativo = 1 WHERE video_ativo = 0", conn)
  ConfigPorta(
    obter: fn(chat_id) { obter(conn, chat_id) },
    salvar: fn(cfg) { salvar(conn, cfg) },
    resetar: fn(chat_id) { resetar(conn, chat_id) },
  )
}

fn obter(conn: sqlight.Connection, chat_id: String) -> Result(Config, Erro) {
  let sql =
    "SELECT chat_id, provedor, modelo, historico_max, prompt_sistema,
            audio_ativo, imagem_ativo, video_ativo, doc_ativo,
            legenda_ativo, idioma, modo_descricao
     FROM configs WHERE chat_id = ?"

  case
    sqlight.query(
      sql,
      on: conn,
      with: [sqlight.text(chat_id)],
      expecting: config_decoder(),
    )
  {
    Ok([cfg, ..]) -> Ok(cfg)
    Ok([]) -> inserir_padrao(conn, chat_id)
    Error(e) -> Error(erro.ErroBancoDados(e.message))
  }
}

fn config_decoder() -> decode.Decoder(Config) {
  use chat_id <- decode.then(decode.at([0], decode.string))
  use provedor <- decode.then(decode.at([1], decode.string))
  use modelo <- decode.then(decode.at([2], decode.string))
  use hist_max <- decode.then(decode.at([3], decode.int))
  use prompt_str <- decode.then(decode.at([4], decode.string))
  use audio <- decode.then(decode.at([5], decode.int))
  use imagem <- decode.then(decode.at([6], decode.int))
  use video <- decode.then(decode.at([7], decode.int))
  use doc <- decode.then(decode.at([8], decode.int))
  use legenda <- decode.then(decode.at([9], decode.int))
  use idioma <- decode.then(decode.at([10], decode.string))
  use modo_str <- decode.then(decode.at([11], decode.string))
  decode.success(Config(
    chat_id: chat_id,
    provedor: provedor,
    modelo: modelo,
    historico_max: hist_max,
    prompt_sistema: case string.trim(prompt_str) {
      "" -> None
      p -> Some(p)
    },
    audio_ativo: audio == 1,
    imagem_ativo: imagem == 1,
    video_ativo: video == 1,
    doc_ativo: doc == 1,
    legenda_ativo: legenda == 1,
    idioma: idioma,
    modo_descricao: config.string_para_modo(modo_str),
  ))
}

fn inserir_padrao(
  conn: sqlight.Connection,
  chat_id: String,
) -> Result(Config, Erro) {
  let cfg = config.padrao(chat_id)
  use _ <- result.try(salvar(conn, cfg))
  Ok(cfg)
}

fn salvar(conn: sqlight.Connection, cfg: Config) -> Result(Nil, Erro) {
  let sql =
    "INSERT INTO configs
       (chat_id, provedor, modelo, historico_max, prompt_sistema,
         audio_ativo, imagem_ativo, video_ativo, doc_ativo,
         legenda_ativo, idioma, modo_descricao)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
     ON CONFLICT(chat_id) DO UPDATE SET
       provedor = excluded.provedor,
       modelo = excluded.modelo,
       historico_max = excluded.historico_max,
       prompt_sistema = excluded.prompt_sistema,
       audio_ativo = excluded.audio_ativo,
       imagem_ativo = excluded.imagem_ativo,
       video_ativo = excluded.video_ativo,
       doc_ativo = excluded.doc_ativo,
       legenda_ativo = excluded.legenda_ativo,
       idioma = excluded.idioma,
       modo_descricao = excluded.modo_descricao"

  let prompt_val = case cfg.prompt_sistema {
    Some(p) -> sqlight.text(p)
    None -> sqlight.text("")
  }

  sqlight.query(
    sql,
    on: conn,
    with: [
      sqlight.text(cfg.chat_id),
      sqlight.text(cfg.provedor),
      sqlight.text(cfg.modelo),
      sqlight.int(cfg.historico_max),
      prompt_val,
      sqlight.int(bool_to_int(cfg.audio_ativo)),
      sqlight.int(bool_to_int(cfg.imagem_ativo)),
      sqlight.int(bool_to_int(cfg.video_ativo)),
      sqlight.int(bool_to_int(cfg.doc_ativo)),
      sqlight.int(bool_to_int(cfg.legenda_ativo)),
      sqlight.text(cfg.idioma),
      sqlight.text(config.modo_para_string(cfg.modo_descricao)),
    ],
    expecting: decode.dynamic,
  )
  |> result.map(fn(_) { Nil })
  |> result.map_error(fn(e) { erro.ErroBancoDados(e.message) })
}

fn resetar(conn: sqlight.Connection, chat_id: String) -> Result(Nil, Erro) {
  sqlight.query(
    "DELETE FROM configs WHERE chat_id = ?",
    on: conn,
    with: [sqlight.text(chat_id)],
    expecting: decode.dynamic,
  )
  |> result.map(fn(_) { Nil })
  |> result.map_error(fn(e) { erro.ErroBancoDados(e.message) })
}

fn bool_to_int(b: Bool) -> Int {
  case b {
    True -> 1
    False -> 0
  }
}
