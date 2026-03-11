// Cache de respostas de IA com TTL.
// Evita chamadas repetidas para prompts idênticos no mesmo contexto.
// Chave: SHA256(prompt + "|" + modelo). TTL: 1h. Máximo: 500 entradas.

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result

// 1 hora em ms
const ttl_ms = 3_600_000

const max_entradas = 500

pub type CacheIA =
  Subject(MensagemCache)

pub type MensagemCache {
  Obter(chave: String, reply: Subject(Option(String)))
  Guardar(chave: String, valor: String)
}

type EntradaCache {
  EntradaCache(valor: String, expira_em: Int)
}

type Estado =
  Dict(String, EntradaCache)

pub fn iniciar() -> Result(CacheIA, actor.StartError) {
  actor.new(dict.new())
  |> actor.on_message(tratar)
  |> actor.start()
  |> result.map(fn(started) { started.data })
}

fn tratar(
  estado: Estado,
  msg: MensagemCache,
) -> actor.Next(Estado, MensagemCache) {
  case msg {
    Obter(chave, reply) -> {
      process.send(reply, buscar(estado, chave))
      actor.continue(estado)
    }
    Guardar(chave, valor) -> actor.continue(inserir(estado, chave, valor))
  }
}

fn buscar(estado: Estado, chave: String) -> Option(String) {
  case dict.get(estado, chave) {
    Error(_) -> None
    Ok(entrada) ->
      case now_ms() < entrada.expira_em {
        True -> Some(entrada.valor)
        False -> None
      }
  }
}

fn inserir(estado: Estado, chave: String, valor: String) -> Estado {
  let estado = case dict.size(estado) >= max_entradas {
    True -> evict(estado)
    False -> estado
  }
  dict.insert(
    estado,
    chave,
    EntradaCache(valor: valor, expira_em: now_ms() + ttl_ms),
  )
}

fn evict(estado: Estado) -> Estado {
  case list.first(dict.to_list(estado)) {
    Ok(#(k, _)) -> dict.delete(estado, k)
    Error(_) -> estado
  }
}

/// Gera chave de cache: SHA256(prompt + "|" + modelo).
pub fn chave(prompt: String, modelo: String) -> String {
  sha256_hex(prompt <> "|" <> modelo)
}

pub fn obter(cache: CacheIA, k: String) -> Option(String) {
  process.call(cache, 1000, fn(reply) { Obter(k, reply) })
}

pub fn guardar(cache: CacheIA, k: String, valor: String) -> Nil {
  process.send(cache, Guardar(k, valor))
}

@external(erlang, "amelie_gleam_ffi", "now_ms")
fn now_ms() -> Int

@external(erlang, "amelie_gleam_ffi", "sha256_hex")
fn sha256_hex(data: String) -> String
