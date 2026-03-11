// Testes do ciclo de auditoria transacional:
// registrar -> enviar -> marcar entregue/falha

import dominio/erro
import dominio/transacao
import gleam/erlang/process
import gleam/option.{None, Some}
import gleeunit/should
import portas/transacao_porta.{type TransacaoPorta, TransacaoPorta}
import portas/whatsapp_porta.{type WhatsappPorta, WhatsappPorta}
import shell/entrega_auditada

fn whatsapp_ok() -> WhatsappPorta {
  WhatsappPorta(
    enviar: fn(_, _) { Ok(Nil) },
    enviar_citando: fn(_, _, _, _) { Ok(Nil) },
    reagir: fn(_, _, _, _) { Ok(Nil) },
  )
}

fn whatsapp_erro() -> WhatsappPorta {
  WhatsappPorta(
    enviar: fn(_, _) { Error(erro.ErroComunicacao("fake")) },
    enviar_citando: fn(_, _, _, _) { Error(erro.ErroComunicacao("fake")) },
    reagir: fn(_, _, _, _) { Ok(Nil) },
  )
}

fn whatsapp_capturar_envio(ref: process.Subject(Bool)) -> WhatsappPorta {
  WhatsappPorta(
    enviar: fn(_, _) {
      process.send(ref, True)
      Ok(Nil)
    },
    enviar_citando: fn(_, _, _, _) {
      process.send(ref, True)
      Ok(Nil)
    },
    reagir: fn(_, _, _, _) { Ok(Nil) },
  )
}

fn transacao_capturar_id(
  ref_entregue: process.Subject(Int),
  id_fixo: Int,
) -> TransacaoPorta {
  TransacaoPorta(
    registrar: fn(tx) { Ok(transacao.Transacao(..tx, id: Some(id_fixo))) },
    atualizar_status: fn(_, _) { Ok(Nil) },
    atualizar_erro: fn(_, _, _) { Ok(Nil) },
    obter_pendentes: fn() { Ok([]) },
    obter_por_chat: fn(_) { Ok([]) },
    marcar_entregue: fn(id) {
      process.send(ref_entregue, id)
      Ok(Nil)
    },
    limpar_antigas: fn() { Ok(Nil) },
  )
}

fn transacao_capturar_erro(
  ref_erro: process.Subject(#(Int, Int)),
  id_fixo: Int,
) -> TransacaoPorta {
  TransacaoPorta(
    registrar: fn(tx) { Ok(transacao.Transacao(..tx, id: Some(id_fixo))) },
    atualizar_status: fn(_, _) { Ok(Nil) },
    atualizar_erro: fn(id, _msg, tentativas) {
      process.send(ref_erro, #(id, tentativas))
      Ok(Nil)
    },
    obter_pendentes: fn() { Ok([]) },
    obter_por_chat: fn(_) { Ok([]) },
    marcar_entregue: fn(_) { Ok(Nil) },
    limpar_antigas: fn() { Ok(Nil) },
  )
}

fn transacao_sem_id() -> TransacaoPorta {
  TransacaoPorta(
    registrar: fn(tx) { Ok(transacao.Transacao(..tx, id: None)) },
    atualizar_status: fn(_, _) { Ok(Nil) },
    atualizar_erro: fn(_, _, _) { Ok(Nil) },
    obter_pendentes: fn() { Ok([]) },
    obter_por_chat: fn(_) { Ok([]) },
    marcar_entregue: fn(_) { Ok(Nil) },
    limpar_antigas: fn() { Ok(Nil) },
  )
}

// ---------------------------------------------------------------------------
// enviar — sucesso
// ---------------------------------------------------------------------------

pub fn envio_sucesso_marca_entregue_test() {
  let ref = process.new_subject()
  let transacoes = transacao_capturar_id(ref, 42)

  entrega_auditada.enviar(
    "chat1",
    "amelie",
    "texto",
    "oi",
    whatsapp_ok(),
    transacoes,
  )
  |> should.be_ok

  let assert Ok(id) = process.receive(ref, 100)
  id |> should.equal(42)
}

// ---------------------------------------------------------------------------
// enviar — falha no envio
// ---------------------------------------------------------------------------

pub fn envio_falha_registra_erro_com_tentativa_test() {
  let ref = process.new_subject()
  let transacoes = transacao_capturar_erro(ref, 7)

  let _ =
    entrega_auditada.enviar(
      "chat1",
      "amelie",
      "texto",
      "oi",
      whatsapp_erro(),
      transacoes,
    )

  let assert Ok(#(id, tentativas)) = process.receive(ref, 100)
  id |> should.equal(7)
  tentativas |> should.equal(1)
}

pub fn envio_falha_propaga_erro_test() {
  entrega_auditada.enviar(
    "chat1",
    "amelie",
    "texto",
    "oi",
    whatsapp_erro(),
    transacao_sem_id(),
  )
  |> should.be_error
}

// ---------------------------------------------------------------------------
// enviar — falha no registro
// ---------------------------------------------------------------------------

pub fn falha_no_registro_nao_envia_test() {
  let enviou = process.new_subject()
  let transacoes =
    TransacaoPorta(
      registrar: fn(_) { Error(erro.ErroBancoDados("db offline")) },
      atualizar_status: fn(_, _) { Ok(Nil) },
      atualizar_erro: fn(_, _, _) { Ok(Nil) },
      obter_pendentes: fn() { Ok([]) },
      obter_por_chat: fn(_) { Ok([]) },
      marcar_entregue: fn(_) { Ok(Nil) },
      limpar_antigas: fn() { Ok(Nil) },
    )

  entrega_auditada.enviar(
    "chat1",
    "amelie",
    "texto",
    "oi",
    whatsapp_capturar_envio(enviou),
    transacoes,
  )
  |> should.be_error

  // Não deve ter enviado
  process.receive(enviou, 50) |> should.be_error
}

// ---------------------------------------------------------------------------
// enviar_citando — sucesso
// ---------------------------------------------------------------------------

pub fn envio_citando_sucesso_marca_entregue_test() {
  let ref = process.new_subject()
  let transacoes = transacao_capturar_id(ref, 55)

  entrega_auditada.enviar_citando(
    "chat1",
    "amelie",
    "ia_texto",
    "resposta",
    "MSG001",
    "user@c.us",
    whatsapp_ok(),
    transacoes,
  )
  |> should.be_ok

  let assert Ok(id) = process.receive(ref, 100)
  id |> should.equal(55)
}

pub fn envio_citando_falha_registra_erro_test() {
  let ref = process.new_subject()
  let transacoes = transacao_capturar_erro(ref, 9)

  let _ =
    entrega_auditada.enviar_citando(
      "chat1",
      "amelie",
      "ia_texto",
      "resposta",
      "MSG001",
      "user@c.us",
      whatsapp_erro(),
      transacoes,
    )

  let assert Ok(#(id, tentativas)) = process.receive(ref, 100)
  id |> should.equal(9)
  tentativas |> should.equal(1)
}
