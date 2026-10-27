// shell/fila_atrasadas.gleam
// Fila serial das mensagens atrasadas: as que o usuário enviou enquanto a
// Amélie estava fora do ar e que chegam todas juntas quando ela volta
// (reconexão, novo pareamento ou a ponte reentregando a própria fila).
// Processa uma por vez, na ordem de chegada, para a volta não virar uma
// rajada de chamadas à IA.

import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision
import gleam/result
import logging

pub type FilaAtrasadas =
  Subject(Mensagem)

pub type Mensagem {
  Processar(tarefa: fn() -> Nil)
}

/// Quanto o horário de envio pode ficar atrás da chegada sem a mensagem ser
/// considerada atrasada. A folga cobre o download de mídia na ponte.
pub const limiar_atraso_s = 120

/// Tempo máximo de uma tarefa. Depois disso a fila segue para a próxima.
pub const tempo_maximo_ms = 300_000

/// A mensagem foi enviada bem antes de chegar. Sem horário (0), não é.
pub fn e_atrasada(timestamp: Int, agora_s: Int) -> Bool {
  timestamp > 0 && agora_s - timestamp > limiar_atraso_s
}

pub fn iniciar() -> Result(FilaAtrasadas, actor.StartError) {
  iniciar_actor(None, tempo_maximo_ms)
  |> result.map(fn(started) { started.data })
}

pub fn iniciar_actor(
  name: Option(process.Name(Mensagem)),
  tempo_maximo_ms: Int,
) -> Result(actor.Started(FilaAtrasadas), actor.StartError) {
  let builder =
    actor.new(tempo_maximo_ms)
    |> actor.on_message(tratar)

  let builder = case name {
    Some(n) -> actor.named(builder, n)
    None -> builder
  }

  actor.start(builder)
}

pub fn supervisionado(
  name: process.Name(Mensagem),
) -> supervision.ChildSpecification(FilaAtrasadas) {
  supervision.worker(fn() { iniciar_actor(Some(name), tempo_maximo_ms) })
}

pub fn enfileirar(fila: FilaAtrasadas, tarefa: fn() -> Nil) -> Nil {
  process.send(fila, Processar(tarefa))
}

fn tratar(tempo_maximo_ms: Int, msg: Mensagem) -> actor.Next(Int, Mensagem) {
  case msg {
    Processar(tarefa) -> {
      executar(tarefa, tempo_maximo_ms)
      actor.continue(tempo_maximo_ms)
    }
  }
}

/// Roda a tarefa em processo próprio e espera ela terminar. Se ela quebrar,
/// a fila não cai junto; se travar, é encerrada no tempo máximo.
fn executar(tarefa: fn() -> Nil, tempo_maximo_ms: Int) -> Nil {
  let pid = process.spawn_unlinked(tarefa)
  let monitor = process.monitor(pid)
  let terminou =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(_) { Nil })

  case process.selector_receive(terminou, tempo_maximo_ms) {
    Ok(Nil) -> Nil
    Error(Nil) -> {
      process.demonitor_process(monitor)
      process.kill(pid)
      logging.log(
        logging.Warning,
        "FilaAtrasadas: mensagem encerrada após "
          <> int.to_string(tempo_maximo_ms / 1000)
          <> "s sem terminar",
      )
    }
  }
}
