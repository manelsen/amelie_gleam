// Actor de manutenção periódica.
// Executa tarefas de limpeza de arquivos órfãos e manutenção do banco de dados.

import dominio/erro
import gleam/erlang/process
import gleam/int
import logging
import portas/transacao_porta.{type TransacaoPorta}
import shell/arquivos_temporarios

// 1 hora em ms
const intervalo_padrao_ms = 3_600_000

// Idade máxima para mídias temporárias em segundos (1 hora)
const max_idade_midia_segundos = 3600

/// Agenda execução periódica das rotinas de manutenção.
pub fn agendar(transacoes: TransacaoPorta, intervalo_ms: Int) -> Nil {
  let _ =
    process.spawn(fn() {
      process.sleep(10_000)
      executar(transacoes)
      loop(transacoes, intervalo_ms)
    })
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

/// Executa ciclo completo de manutenção: varredura de mídias órfãs e limpeza de banco.
pub fn executar(transacoes: TransacaoPorta) -> Nil {
  logging.log(logging.Info, "Manutenção: varrendo mídias temporárias órfãs")
  case arquivos_temporarios.limpar_antigos(max_idade_midia_segundos) {
    Ok(qtd) ->
      logging.log(
        logging.Info,
        "Manutenção: limpeza de mídias concluída ("
          <> int.to_string(qtd)
          <> " arquivos removidos)",
      )
    Error(e) ->
      logging.log(
        logging.Warning,
        "Manutenção: falha na limpeza de mídias temporárias: " <> e,
      )
  }

  logging.log(
    logging.Info,
    "Manutenção: limpando transações antigas e otimizando banco",
  )
  case transacoes.limpar_antigas() {
    Ok(_) ->
      logging.log(
        logging.Info,
        "Manutenção: limpeza de transações e otimização do banco concluída",
      )
    Error(e) ->
      logging.log(
        logging.Warning,
        "Manutenção: falha na limpeza de transações: " <> erro.descricao(e),
      )
  }
}
