// Adaptador SQLite para configuração por chat.

import dominio/config.{type Config, Config}
import dominio/erro.{type Erro}
import dominio/id_chat.{type IdChat}
import dominio/provedor
import gleam/dynamic/decode
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import logging
import portas/config_porta.{type ConfigPorta, ConfigPorta}
import sqlight

const schema = "CREATE TABLE IF NOT EXISTS configs (
  chat_id TEXT PRIMARY KEY,
  provedor TEXT NOT NULL DEFAULT 'gemini',
  modelo TEXT NOT NULL DEFAULT 'gemini-3.5-flash-lite',
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
  let _ = sqlight.exec(schema_migracoes, conn)
  // `criar` roda a cada boot, e a migração de modelo rodava junto: a troca
  // feita pelo admin com `.modelo` para gemini-3.8-flash ou
  // gemini-2.5-flash-lite se desfazia no reinício seguinte. Agora ela roda
  // uma vez só por banco.
  migrar_uma_vez(
    conn,
    "modelo_padrao_gemini_3_5_flash_lite",
    "UPDATE configs SET modelo = 'gemini-3.5-flash-lite' WHERE provedor = 'gemini' AND modelo IN ('gemini-3.8-flash', 'gemini-3.1-flash-lite', 'gemini-2.5-flash-lite')",
  )
  ConfigPorta(
    obter: fn(chat_id) { obter(conn, chat_id) },
    salvar: fn(cfg) { salvar(conn, cfg) },
    resetar: fn(chat_id) { resetar(conn, chat_id) },
  )
}

const schema_migracoes = "CREATE TABLE IF NOT EXISTS migracoes (
  nome TEXT PRIMARY KEY,
  aplicada_em INTEGER NOT NULL DEFAULT (unixepoch())
)"

/// Executa `sql` só se a migração `nome` ainda não foi registrada, e a
/// registra na mesma transação.
fn migrar_uma_vez(conn: sqlight.Connection, nome: String, sql: String) -> Nil {
  let pendente =
    sqlight.query(
      "SELECT 1 FROM migracoes WHERE nome = ?",
      on: conn,
      with: [sqlight.text(nome)],
      expecting: decode.at([0], decode.int),
    )
  case pendente {
    Ok([]) -> {
      let resultado = {
        use _ <- result.try(sqlight.exec("BEGIN IMMEDIATE", conn))
        let aplicada = {
          use _ <- result.try(sqlight.exec(sql, conn))
          sqlight.query(
            "INSERT INTO migracoes (nome) VALUES (?)",
            on: conn,
            with: [sqlight.text(nome)],
            expecting: decode.dynamic,
          )
        }
        // Também se o COMMIT falhar (banco ocupado): a transação aberta
        // engoliria as escritas seguintes nesta conexão.
        case result.try(aplicada, fn(_) { sqlight.exec("COMMIT", conn) }) {
          Ok(_) -> Ok(Nil)
          Error(e) -> {
            let _ = sqlight.exec("ROLLBACK", conn)
            Error(e)
          }
        }
      }
      case resultado {
        Ok(_) -> logging.log(logging.Info, "Migração aplicada: " <> nome)
        Error(e) ->
          logging.log(
            logging.Warning,
            "Migração " <> nome <> " falhou: " <> e.message,
          )
      }
    }
    Ok(_) -> Nil
    // Sem a tabela migracoes (criação falhou) a consulta falha aqui; sem
    // este aviso a migração deixaria de rodar em silêncio a cada boot.
    Error(e) ->
      logging.log(
        logging.Warning,
        "Migração " <> nome <> " não verificada: " <> e.message,
      )
  }
}

fn obter(conn: sqlight.Connection, chat_id: IdChat) -> Result(Config, Erro) {
  let sql =
    "SELECT chat_id, provedor, modelo, historico_max, prompt_sistema,
            audio_ativo, imagem_ativo, video_ativo, doc_ativo,
            legenda_ativo, idioma, modo_descricao
     FROM configs WHERE chat_id = ?"

  case
    sqlight.query(
      sql,
      on: conn,
      with: [sqlight.text(id_chat.para_texto(chat_id))],
      expecting: config_decoder(),
    )
  {
    Ok([cfg, ..]) -> Ok(cfg)
    Ok([]) -> inserir_padrao(conn, chat_id)
    Error(e) -> Error(erro.ErroBancoDados(e.message))
  }
}

fn config_decoder() -> decode.Decoder(Config) {
  use chat_id <- decode.then(decode.at([0], id_chat.decoder()))
  // Um nome desconhecido no banco segue para o Gemini, como antes do tipo.
  use provedor <- decode.then(
    decode.at([1], decode.string)
    |> decode.map(fn(nome) {
      provedor.de_string(nome) |> result.unwrap(provedor.Gemini)
    }),
  )
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
  chat_id: IdChat,
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
      sqlight.text(id_chat.para_texto(cfg.chat_id)),
      sqlight.text(provedor.para_string(cfg.provedor)),
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

fn resetar(conn: sqlight.Connection, chat_id: IdChat) -> Result(Nil, Erro) {
  sqlight.query(
    "DELETE FROM configs WHERE chat_id = ?",
    on: conn,
    with: [sqlight.text(id_chat.para_texto(chat_id))],
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
