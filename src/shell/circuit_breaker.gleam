// Circuit breaker como OTP actor.
// Protege chamadas de IA contra falhas em cascata.
// Estados: Fechado (normal) → Aberto (bloqueado) → SemiAberto (prova única com contenção)

import gleam/erlang/process.{type Subject}
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision
import gleam/result

pub const limite_falhas_padrao = 5

pub const reset_ms_padrao = 60_000

pub const timeout_probe_ms_padrao = 15_000

pub type Estado {
  Fechado(falhas: Int)
  Aberto(ultima_falha_ms: Int)
  SemiAberto(probe_em_voo: Bool, desde_ms: Int)
}

pub type Config {
  Config(limite_falhas: Int, reset_ms: Int, timeout_probe_ms: Int)
}

pub type EstadoActor {
  EstadoActor(estado: Estado, config: Config)
}

pub type Mensagem {
  Verificar(Subject(Bool))
  ObterEstado(Subject(Estado))
  Sucesso
  Falha
}

pub fn iniciar() -> Result(Subject(Mensagem), actor.StartError) {
  iniciar_com_config(Config(
    limite_falhas: limite_falhas_padrao,
    reset_ms: reset_ms_padrao,
    timeout_probe_ms: timeout_probe_ms_padrao,
  ))
}

pub fn iniciar_com_config(
  config: Config,
) -> Result(Subject(Mensagem), actor.StartError) {
  iniciar_actor(config, None)
  |> result.map(fn(started) { started.data })
}

pub fn iniciar_actor(
  config: Config,
  name: Option(process.Name(Mensagem)),
) -> Result(actor.Started(Subject(Mensagem)), actor.StartError) {
  let builder =
    actor.new(EstadoActor(estado: Fechado(0), config: config))
    |> actor.on_message(tratar)

  let builder = case name {
    Some(n) -> actor.named(builder, n)
    None -> builder
  }

  actor.start(builder)
}

pub fn supervisionado(
  name: process.Name(Mensagem),
) -> supervision.ChildSpecification(Subject(Mensagem)) {
  supervision.worker(fn() {
    iniciar_actor(
      Config(
        limite_falhas: limite_falhas_padrao,
        reset_ms: reset_ms_padrao,
        timeout_probe_ms: timeout_probe_ms_padrao,
      ),
      Some(name),
    )
  })
}

fn tratar(
  actor_state: EstadoActor,
  msg: Mensagem,
) -> actor.Next(EstadoActor, Mensagem) {
  case msg {
    Verificar(reply) -> {
      let #(pode, novo_estado) = checar(actor_state.estado, actor_state.config)
      process.send(reply, pode)
      actor.continue(EstadoActor(..actor_state, estado: novo_estado))
    }
    ObterEstado(reply) -> {
      process.send(reply, actor_state.estado)
      actor.continue(actor_state)
    }
    Sucesso -> actor.continue(EstadoActor(..actor_state, estado: Fechado(0)))
    Falha -> {
      let novo_estado = ao_falhar(actor_state.estado, actor_state.config)
      actor.continue(EstadoActor(..actor_state, estado: novo_estado))
    }
  }
}

pub fn checar(estado: Estado, config: Config) -> #(Bool, Estado) {
  let agora = now_ms()
  case estado {
    Fechado(_) -> #(True, estado)
    Aberto(ultima) ->
      case agora - ultima > config.reset_ms {
        True -> #(True, SemiAberto(probe_em_voo: True, desde_ms: agora))
        False -> #(False, estado)
      }
    SemiAberto(probe_em_voo, desde_ms) ->
      case probe_em_voo {
        True ->
          case agora - desde_ms > config.timeout_probe_ms {
            True -> #(True, SemiAberto(probe_em_voo: True, desde_ms: agora))
            False -> #(False, estado)
          }
        False -> #(True, SemiAberto(probe_em_voo: True, desde_ms: agora))
      }
  }
}

pub fn ao_falhar(estado: Estado, config: Config) -> Estado {
  case estado {
    Fechado(f) -> {
      let novo = f + 1
      case novo >= config.limite_falhas {
        True -> Aberto(now_ms())
        False -> Fechado(novo)
      }
    }
    SemiAberto(..) -> Aberto(now_ms())
    Aberto(_) -> Aberto(now_ms())
  }
}

/// Verifica se o CB permite execução (False = bloqueado).
/// Em caso de timeout ou indisponibilidade temporária do actor, não bloqueia por padrão.
pub fn pode_executar(cb: Subject(Mensagem)) -> Bool {
  let reply = process.new_subject()
  process.send(cb, Verificar(reply))
  case process.receive(reply, 1000) {
    Ok(pode) -> pode
    Error(_) -> True
  }
}

/// Obtém o estado atual do CB para inspeção e testes.
pub fn obter_estado(cb: Subject(Mensagem)) -> Estado {
  let reply = process.new_subject()
  process.send(cb, ObterEstado(reply))
  case process.receive(reply, 1000) {
    Ok(estado) -> estado
    Error(_) -> Fechado(0)
  }
}

pub fn registrar_sucesso(cb: Subject(Mensagem)) -> Nil {
  process.send(cb, Sucesso)
}

pub fn registrar_falha(cb: Subject(Mensagem)) -> Nil {
  process.send(cb, Falha)
}

@external(erlang, "amelie_gleam_ffi", "now_ms")
fn now_ms() -> Int
