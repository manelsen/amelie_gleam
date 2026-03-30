// Testes do ciclo de retry da fila offline.

import dominio/erro
import dominio/transacao as t
import gleam/erlang/process
import gleam/option.{None, Some}
import gleeunit/should
import portas/transacao_porta.{TransacaoPorta}
import portas/whatsapp_porta.{WhatsappPorta}
import shell/fila_offline

fn tx_pendente(id: Int, tentativas: Int) -> t.Transacao {
  t.Transacao(
    id: Some(id),
    chat_id: "chat1",
    remetente: "amelie",
    tipo: "texto",
    conteudo: "mensagem pendente",
    status: t.Falha,
    criado_em: 0,
    atualizado_em: None,
    tentativas: tentativas,
    erro: None,
  )
}

// ---------------------------------------------------------------------------
// Retry com sucesso
// ---------------------------------------------------------------------------

pub fn retry_sucesso_marca_entregue_test() {
  let ref_entregue = process.new_subject()
  let transacoes =
    TransacaoPorta(
      registrar: fn(tx) { Ok(tx) },
      atualizar_status: fn(_, _) { Ok(Nil) },
      atualizar_erro: fn(_, _, _) { Ok(Nil) },
      obter_pendentes: fn() { Ok([tx_pendente(99, 1)]) },
      obter_por_chat: fn(_) { Ok([]) },
      marcar_entregue: fn(id) {
        process.send(ref_entregue, id)
        Ok(Nil)
      },
      limpar_antigas: fn() { Ok(Nil) },
      foi_recebida: fn(_) { Ok(False) },
      marcar_recebida: fn(_) { Ok(Nil) },
    )
  let whatsapp =
    WhatsappPorta(
      enviar: fn(_, _) { Ok(Nil) },
      enviar_citando: fn(_, _, _, _) { Ok(Nil) },
      reagir: fn(_, _, _, _) { Ok(Nil) },
    )

  let assert Ok(fila) = fila_offline.iniciar(transacoes, whatsapp, 3)
  process.send(fila, fila_offline.ProcessarPendentes)
  process.sleep(50)

  let assert Ok(id) = process.receive(ref_entregue, 100)
  id |> should.equal(99)
}

// ---------------------------------------------------------------------------
// Retry com falha
// ---------------------------------------------------------------------------

pub fn retry_falha_atualiza_tentativas_test() {
  let ref_erro = process.new_subject()
  let transacoes =
    TransacaoPorta(
      registrar: fn(tx) { Ok(tx) },
      atualizar_status: fn(_, _) { Ok(Nil) },
      atualizar_erro: fn(id, _msg, tentativas) {
        process.send(ref_erro, #(id, tentativas))
        Ok(Nil)
      },
      obter_pendentes: fn() { Ok([tx_pendente(5, 1)]) },
      obter_por_chat: fn(_) { Ok([]) },
      marcar_entregue: fn(_) { Ok(Nil) },
      limpar_antigas: fn() { Ok(Nil) },
      foi_recebida: fn(_) { Ok(False) },
      marcar_recebida: fn(_) { Ok(Nil) },
    )
  let whatsapp =
    WhatsappPorta(
      enviar: fn(_, _) { Error(erro.ErroComunicacao("offline")) },
      enviar_citando: fn(_, _, _, _) { Error(erro.ErroComunicacao("offline")) },
      reagir: fn(_, _, _, _) { Ok(Nil) },
    )

  let assert Ok(fila) = fila_offline.iniciar(transacoes, whatsapp, 3)
  process.send(fila, fila_offline.ProcessarPendentes)
  process.sleep(50)

  let assert Ok(#(id, tentativas)) = process.receive(ref_erro, 100)
  id |> should.equal(5)
  tentativas |> should.equal(2)
}

// ---------------------------------------------------------------------------
// Descarte após máximo de tentativas
// ---------------------------------------------------------------------------

pub fn retry_descarta_apos_max_tentativas_test() {
  let ref_status = process.new_subject()
  let transacoes =
    TransacaoPorta(
      registrar: fn(tx) { Ok(tx) },
      atualizar_status: fn(id, status) {
        process.send(ref_status, #(id, status))
        Ok(Nil)
      },
      atualizar_erro: fn(_, _, _) { Ok(Nil) },
      obter_pendentes: fn() { Ok([tx_pendente(3, 3)]) },
      obter_por_chat: fn(_) { Ok([]) },
      marcar_entregue: fn(_) { Ok(Nil) },
      limpar_antigas: fn() { Ok(Nil) },
      foi_recebida: fn(_) { Ok(False) },
      marcar_recebida: fn(_) { Ok(Nil) },
    )
  let whatsapp =
    WhatsappPorta(
      enviar: fn(_, _) { Error(erro.ErroComunicacao("offline")) },
      enviar_citando: fn(_, _, _, _) { Error(erro.ErroComunicacao("offline")) },
      reagir: fn(_, _, _, _) { Ok(Nil) },
    )

  let assert Ok(fila) = fila_offline.iniciar(transacoes, whatsapp, 3)
  process.send(fila, fila_offline.ProcessarPendentes)
  process.sleep(50)

  let assert Ok(#(id, status)) = process.receive(ref_status, 100)
  id |> should.equal(3)
  status |> should.equal(t.Descartada)
}

// ---------------------------------------------------------------------------
// Sem pendentes
// ---------------------------------------------------------------------------

pub fn sem_pendentes_nao_envia_test() {
  let ref_enviou = process.new_subject()
  let transacoes =
    TransacaoPorta(
      registrar: fn(tx) { Ok(tx) },
      atualizar_status: fn(_, _) { Ok(Nil) },
      atualizar_erro: fn(_, _, _) { Ok(Nil) },
      obter_pendentes: fn() { Ok([]) },
      obter_por_chat: fn(_) { Ok([]) },
      marcar_entregue: fn(_) { Ok(Nil) },
      limpar_antigas: fn() { Ok(Nil) },
      foi_recebida: fn(_) { Ok(False) },
      marcar_recebida: fn(_) { Ok(Nil) },
    )
  let whatsapp =
    WhatsappPorta(
      enviar: fn(_, _) {
        process.send(ref_enviou, True)
        Ok(Nil)
      },
      enviar_citando: fn(_, _, _, _) { Ok(Nil) },
      reagir: fn(_, _, _, _) { Ok(Nil) },
    )

  let assert Ok(fila) = fila_offline.iniciar(transacoes, whatsapp, 3)
  process.send(fila, fila_offline.ProcessarPendentes)
  process.sleep(50)

  process.receive(ref_enviou, 50) |> should.be_error
}

// ---------------------------------------------------------------------------
// Transação sem id é ignorada
// ---------------------------------------------------------------------------

pub fn tx_sem_id_e_ignorada_test() {
  let ref_enviou = process.new_subject()
  let tx_sem_id =
    t.Transacao(
      id: None,
      chat_id: "chat1",
      remetente: "amelie",
      tipo: "texto",
      conteudo: "órfã",
      status: t.Falha,
      criado_em: 0,
      atualizado_em: None,
      tentativas: 0,
      erro: None,
    )
  let transacoes =
    TransacaoPorta(
      registrar: fn(tx) { Ok(tx) },
      atualizar_status: fn(_, _) { Ok(Nil) },
      atualizar_erro: fn(_, _, _) { Ok(Nil) },
      obter_pendentes: fn() { Ok([tx_sem_id]) },
      obter_por_chat: fn(_) { Ok([]) },
      marcar_entregue: fn(_) { Ok(Nil) },
      limpar_antigas: fn() { Ok(Nil) },
      foi_recebida: fn(_) { Ok(False) },
      marcar_recebida: fn(_) { Ok(Nil) },
    )
  let whatsapp =
    WhatsappPorta(
      enviar: fn(_, _) {
        process.send(ref_enviou, True)
        Ok(Nil)
      },
      enviar_citando: fn(_, _, _, _) { Ok(Nil) },
      reagir: fn(_, _, _, _) { Ok(Nil) },
    )

  let assert Ok(fila) = fila_offline.iniciar(transacoes, whatsapp, 3)
  process.send(fila, fila_offline.ProcessarPendentes)
  process.sleep(50)

  process.receive(ref_enviou, 50) |> should.be_error
}
