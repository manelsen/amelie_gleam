// Circuit breaker como OTP actor.
// Protege chamadas de IA contra falhas em cascata.
// Estados: Fechado (normal) → Aberto (bloqueado) → SemiAberto (testando)

import gleam/erlang/process.{type Subject}
import gleam/otp/actor
import gleam/result

const limite_falhas = 5

const reset_ms = 60_000

pub type Estado {
  Fechado(falhas: Int)
  Aberto(ultima_falha_ms: Int)
  SemiAberto
}

pub type Mensagem {
  Verificar(Subject(Bool))
  Sucesso
  Falha
}

pub fn iniciar() -> Result(Subject(Mensagem), actor.StartError) {
  actor.new(Fechado(0))
  |> actor.on_message(tratar)
  |> actor.start()
  |> result.map(fn(started) { started.data })
}

fn tratar(estado: Estado, msg: Mensagem) -> actor.Next(Estado, Mensagem) {
  case msg {
    Verificar(reply) -> {
      let #(pode, novo) = checar(estado)
      process.send(reply, pode)
      actor.continue(novo)
    }
    Sucesso -> actor.continue(Fechado(0))
    Falha -> actor.continue(ao_falhar(estado))
  }
}

fn checar(estado: Estado) -> #(Bool, Estado) {
  case estado {
    Fechado(_) -> #(True, estado)
    SemiAberto -> #(True, estado)
    Aberto(ultima) ->
      case now_ms() - ultima > reset_ms {
        True -> #(True, SemiAberto)
        False -> #(False, estado)
      }
  }
}

fn ao_falhar(estado: Estado) -> Estado {
  case estado {
    Fechado(f) -> {
      let novo = f + 1
      case novo >= limite_falhas {
        True -> Aberto(now_ms())
        False -> Fechado(novo)
      }
    }
    SemiAberto -> Aberto(now_ms())
    Aberto(_) -> estado
  }
}

/// Verifica se o CB permite execução (False = bloqueado).
pub fn pode_executar(cb: Subject(Mensagem)) -> Bool {
  process.call(cb, 1000, fn(reply) { Verificar(reply) })
}

pub fn registrar_sucesso(cb: Subject(Mensagem)) -> Nil {
  process.send(cb, Sucesso)
}

pub fn registrar_falha(cb: Subject(Mensagem)) -> Nil {
  process.send(cb, Falha)
}

@external(erlang, "amelie_gleam_ffi", "now_ms")
fn now_ms() -> Int
