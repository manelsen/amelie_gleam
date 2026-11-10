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
/// `tempo_maximo_ms`. Quem chama continua vivo em qualquer desfecho. Se quem
/// chama morrer antes, a tarefa morre junto: um ator reiniciado não pode
/// ter o job antigo correndo em paralelo com o novo.
pub fn executar(tarefa: fn() -> Nil, tempo_maximo_ms: Int) -> Desfecho {
  let chamador = process.self()
  let pid = process.spawn_unlinked(fn() { guardar(chamador, tarefa) })
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

/// Processo intermediário entre quem chama e a tarefa. A tarefa é ligada a
/// ele (morre se ele for encerrado no tempo máximo); ele vigia quem chama e
/// encerra a tarefa se quem chama morrer. Não há vínculo com quem chama: uma
/// falha da tarefa não o derruba, só aparece no monitor dele.
fn guardar(chamador: process.Pid, tarefa: fn() -> Nil) -> Nil {
  let do_chamador = process.monitor(chamador)
  let trabalho = process.spawn(tarefa)
  let do_trabalho = process.monitor(trabalho)
  let fim =
    process.new_selector()
    |> process.select_specific_monitor(do_trabalho, fn(down) {
      case down {
        process.ProcessDown(reason: process.Normal, ..) -> True
        _ -> False
      }
    })
    |> process.select_specific_monitor(do_chamador, fn(_) {
      process.kill(trabalho)
      True
    })
  case process.selector_receive_forever(fim) {
    True -> Nil
    // A tarefa quebrou: o guardião sai com erro para quem chama ver Quebrou.
    False -> panic as "tarefa isolada quebrou"
  }
}
