import dominio/erro
import dominio/transacao as t
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import logging
import portas/mensageiro_porta.{type MensageiroPorta}
import portas/transacao_porta.{type TransacaoPorta}

pub type FilaOffline =
  process.Subject(Mensagem)

pub type Mensagem {
  ProcessarPendentes
  Parar
}

pub type State {
  State(
    transacoes: TransacaoPorta,
    mensageiro: MensageiroPorta,
    tentativas_max: Int,
  )
}

/// Identifica se um erro é permanente (não deve ser retentado).
pub fn e_erro_definitivo(e: erro.Erro) -> Bool {
  case e {
    erro.ErroValidacao(..) -> True
    erro.ErroNaoAutorizado -> True
    erro.ErroComandoDesconhecido(..) -> True
    erro.ErroComunicacao(desc) -> {
      let desc_baixa = string.lowercase(desc)
      string.contains(desc_baixa, "invalid_chat_id")
      || string.contains(desc_baixa, "invalid_json")
      || string.contains(desc_baixa, "chat not found")
      || string.contains(desc_baixa, "bot was blocked")
      || string.contains(desc_baixa, "user is deactivated")
      || string.contains(desc_baixa, "whatsapp_logged_out")
      || string.contains(desc_baixa, "whatsapp_session_deleted")
      || string.contains(desc_baixa, "status 400")
      || string.contains(desc_baixa, "status 403")
      || string.contains(desc_baixa, "status 404")
    }
    _ -> False
  }
}

pub fn iniciar(
  transacoes: TransacaoPorta,
  mensageiro: MensageiroPorta,
  tentativas_max: Int,
) -> Result(FilaOffline, actor.StartError) {
  let state =
    State(
      transacoes: transacoes,
      mensageiro: mensageiro,
      tentativas_max: tentativas_max,
    )

  actor.new(state)
  |> actor.on_message(handle_message)
  |> actor.start()
  |> result.map(fn(started) { started.data })
}

fn handle_message(state: State, msg: Mensagem) -> actor.Next(State, Mensagem) {
  case msg {
    ProcessarPendentes -> {
      logging.log(logging.Debug, "FilaOffline: processando pendentes")
      processar_pendentes(state)
    }

    Parar -> {
      logging.log(logging.Info, "FilaOffline: parando")
      actor.stop()
    }
  }
}

fn processar_pendentes(state: State) -> actor.Next(State, Mensagem) {
  case state.transacoes.obter_pendentes() {
    Ok([]) -> {
      logging.log(logging.Debug, "FilaOffline: nenhuma transação pendente")
      actor.continue(state)
    }

    Ok(pendentes) -> {
      logging.log(
        logging.Info,
        "FilaOffline: encontradas "
          <> int.to_string(list.length(pendentes))
          <> " transações pendentes",
      )
      let _ = list.each(pendentes, fn(tx) { retry_transacao(state, tx) })
      actor.continue(state)
    }

    Error(e) -> {
      logging.log(
        logging.Warning,
        "FilaOffline: erro ao buscar pendentes: " <> erro.descricao(e),
      )
      actor.continue(state)
    }
  }
}

fn retry_transacao(state: State, tx: t.Transacao) -> Nil {
  case tx.id {
    None -> Nil
    Some(id) -> {
      case tx.tentativas < state.tentativas_max {
        True -> {
          logging.log(
            logging.Info,
            "FilaOffline: retry transação "
              <> int.to_string(id)
              <> " (tentativa "
              <> int.to_string(tx.tentativas + 1)
              <> ")",
          )

          case state.mensageiro.enviar(tx.chat_id, tx.conteudo) {
            Ok(_) -> {
              let _ = state.transacoes.marcar_entregue(id)
              logging.log(
                logging.Info,
                "FilaOffline: transação "
                  <> int.to_string(id)
                  <> " enviada com sucesso",
              )
            }
            Error(e) -> {
              case e_erro_definitivo(e) {
                True -> {
                  let _ =
                    state.transacoes.atualizar_erro(
                      id,
                      erro.descricao(e) <> " (descarte definitivo)",
                      tx.tentativas + 1,
                    )
                  let _ = state.transacoes.atualizar_status(id, t.Descartada)
                  logging.log(
                    logging.Warning,
                    "FilaOffline: transação "
                      <> int.to_string(id)
                      <> " descartada imediatamente por erro definitivo: "
                      <> erro.descricao(e),
                  )
                }
                False -> {
                  let _ =
                    state.transacoes.atualizar_erro(
                      id,
                      erro.descricao(e),
                      tx.tentativas + 1,
                    )
                  logging.log(
                    logging.Warning,
                    "FilaOffline: falha ao enviar transação "
                      <> int.to_string(id)
                      <> ": "
                      <> erro.descricao(e),
                  )
                }
              }
            }
          }
        }
        False -> {
          logging.log(
            logging.Warning,
            "FilaOffline: transação "
              <> int.to_string(id)
              <> " atingiu máximo de tentativas",
          )
          let _ = state.transacoes.atualizar_status(id, t.Descartada)
          Nil
        }
      }
    }
  }
}

pub fn agendar_processamento(fila: FilaOffline, intervalo_ms: Int) -> Nil {
  let _ = process.spawn(fn() { loop_processamento(fila, intervalo_ms) })
  Nil
}

fn loop_processamento(fila: FilaOffline, intervalo_ms: Int) -> Nil {
  process.send(fila, ProcessarPendentes)
  process.sleep(intervalo_ms)
  loop_processamento(fila, intervalo_ms)
}
