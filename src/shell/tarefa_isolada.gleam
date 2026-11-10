// Execução isolada de uma tarefa: roda em processo próprio, monitorado, para
// que um panic ou uma trava não derrube o ator que a disparou (e, com ele,
// tudo o que estava na fila desse ator).

import gleam/erlang/process

pub type Desfecho {
  /// A tarefa terminou normalmente.
  Terminou
  /// A tarefa quebrou (panic ou exceção).
  Quebrou
  /// A tarefa passou do tempo máximo e foi encerrada.
  Estourou
}

/// Roda `tarefa` em processo próprio e espera ela terminar, até
/// `tempo_maximo_ms`. Quem chama continua vivo em qualquer desfecho.
pub fn executar(tarefa: fn() -> Nil, tempo_maximo_ms: Int) -> Desfecho {
  let pid = process.spawn_unlinked(tarefa)
  let monitor = process.monitor(pid)
  let terminou =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) {
      case down {
        process.ProcessDown(reason: process.Normal, ..) -> Terminou
        _ -> Quebrou
      }
    })

  case process.selector_receive(terminou, tempo_maximo_ms) {
    Ok(desfecho) -> desfecho
    Error(Nil) -> {
      process.demonitor_process(monitor)
      process.kill(pid)
      Estourou
    }
  }
}
