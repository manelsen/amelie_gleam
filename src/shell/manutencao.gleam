// Actor de manutenção periódica como OTP Actor supervisionado.
// Executa tarefas de limpeza de arquivos órfãos e manutenção do banco de dados.

import dominio/erro
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision
import logging
import portas/transacao_porta.{type TransacaoPorta}
import shell/arquivos_temporarios

// 1 hora em ms
pub const intervalo_padrao_ms = 3_600_000

// Idade máxima para mídias temporárias em segundos (1 hora)
const max_idade_midia_segundos = 3600

pub type MensagemManutencao {
  Tick
  ExecutarManutencao(reply: Subject(Nil))
}

pub type EstadoManutencao {
  EstadoManutencao(
    transacoes: TransacaoPorta,
    intervalo_ms: Int,
    self_name: process.Name(MensagemManutencao),
  )
}

pub fn iniciar_actor(
  transacoes: TransacaoPorta,
  intervalo_ms: Int,
  name: Option(process.Name(MensagemManutencao)),
) -> Result(actor.Started(Subject(MensagemManutencao)), actor.StartError) {
  let name_val = case name {
    Some(n) -> n
    None -> process.new_name("amelie_manutencao")
  }

  let builder =
    actor.new(EstadoManutencao(
      transacoes: transacoes,
      intervalo_ms: intervalo_ms,
      self_name: name_val,
    ))
    |> actor.on_message(tratar)
    |> actor.named(name_val)

  case actor.start(builder) {
    Ok(started) -> {
      let subj = process.named_subject(name_val)
      process.send_after(subj, 10_000, Tick)
      Ok(started)
    }
    Error(err) -> Error(err)
  }
}

pub fn supervisionado(
  transacoes: TransacaoPorta,
  intervalo_ms: Int,
  name: process.Name(MensagemManutencao),
) -> supervision.ChildSpecification(Subject(MensagemManutencao)) {
  supervision.worker(fn() {
    iniciar_actor(transacoes, intervalo_ms, Some(name))
  })
}

fn tratar(
  estado: EstadoManutencao,
  msg: MensagemManutencao,
) -> actor.Next(EstadoManutencao, MensagemManutencao) {
  case msg {
    Tick -> {
      executar(estado.transacoes)
      let subj = process.named_subject(estado.self_name)
      process.send_after(subj, estado.intervalo_ms, Tick)
      actor.continue(estado)
    }
    ExecutarManutencao(reply) -> {
      executar(estado.transacoes)
      process.send(reply, Nil)
      actor.continue(estado)
    }
  }
}

/// Dispara execução imediata de manutenção via ator.
pub fn executar_agora(manutencao: Subject(MensagemManutencao)) -> Nil {
  let reply = process.new_subject()
  process.send(manutencao, ExecutarManutencao(reply))
  case process.receive(reply, 10_000) {
    Ok(Nil) -> Nil
    Error(_) -> Nil
  }
}

/// Agenda execução periódica das rotinas de manutenção.
pub fn agendar(transacoes: TransacaoPorta, intervalo_ms: Int) -> Nil {
  let _ = iniciar_actor(transacoes, intervalo_ms, None)
  Nil
}

pub fn agendar_padrao(transacoes: TransacaoPorta) -> Nil {
  agendar(transacoes, intervalo_padrao_ms)
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
