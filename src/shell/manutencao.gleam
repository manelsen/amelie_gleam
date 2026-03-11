// Actor de manutenção periódica.
// Executa tarefas de limpeza que não afetam o fluxo principal.

import dominio/erro
import gleam/erlang/process
import logging
import portas/transacao_porta.{type TransacaoPorta}

// 6 horas em ms
const intervalo_padrao_ms = 21_600_000

/// Agenda execução periódica das rotinas de manutenção.
pub fn agendar(transacoes: TransacaoPorta, intervalo_ms: Int) -> Nil {
  let _ = process.spawn(fn() { loop(transacoes, intervalo_ms) })
  Nil
}

pub fn agendar_padrao(transacoes: TransacaoPorta) -> Nil {
  agendar(transacoes, intervalo_padrao_ms)
}

fn loop(transacoes: TransacaoPorta, intervalo_ms: Int) -> Nil {
  process.sleep(intervalo_ms)
  executar(transacoes)
  loop(transacoes, intervalo_ms)
}

fn executar(transacoes: TransacaoPorta) -> Nil {
  logging.log(logging.Info, "Manutenção: limpando transações antigas")
  case transacoes.limpar_antigas() {
    Ok(_) ->
      logging.log(logging.Info, "Manutenção: limpeza de transações concluída")
    Error(e) ->
      logging.log(
        logging.Warning,
        "Manutenção: falha na limpeza de transações: " <> erro.descricao(e),
      )
  }
}
