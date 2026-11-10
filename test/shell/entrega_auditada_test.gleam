// Testes do ciclo de auditoria transacional:
// registrar -> enviar -> marcar entregue/falha

import dominio/erro
import dominio/transacao
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import helpers/fixtures
import portas/mensageiro_porta.{type MensageiroPorta, MensageiroPorta}
import portas/transacao_porta.{type TransacaoPorta, TransacaoPorta}
import shell/entrega_auditada

fn mensageiro_ok() -> MensageiroPorta {
  MensageiroPorta(
    enviar: fn(_, _) { Ok(Nil) },
    enviar_citando: fn(_, _, _, _) { Ok(Nil) },
    reagir: fn(_, _, _, _) { Ok(Nil) },
  )
}

fn mensageiro_erro() -> MensageiroPorta {
  MensageiroPorta(
    enviar: fn(_, _) { Error(erro.ErroComunicacao("fake")) },
    enviar_citando: fn(_, _, _, _) { Error(erro.ErroComunicacao("fake")) },
    reagir: fn(_, _, _, _) { Ok(Nil) },
  )
}

fn mensageiro_capturar_envio(ref: process.Subject(Bool)) -> MensageiroPorta {
  MensageiroPorta(
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
    foi_recebida: fn(_, _) { Ok(False) },
    marcar_recebida: fn(_, _) { Ok(Nil) },
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
    foi_recebida: fn(_, _) { Ok(False) },
    marcar_recebida: fn(_, _) { Ok(Nil) },
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
    foi_recebida: fn(_, _) { Ok(False) },
    marcar_recebida: fn(_, _) { Ok(Nil) },
  )
}

// ---------------------------------------------------------------------------
// enviar — sucesso
// ---------------------------------------------------------------------------

pub fn envio_sucesso_marca_entregue_test() {
  let ref = process.new_subject()
  let transacoes = transacao_capturar_id(ref, 42)

  entrega_auditada.enviar(
    fixtures.id("chat1@c.us"),
    transacao.RespostaTexto,
    "oi",
    mensageiro_ok(),
    transacoes,
  )
  |> should.be_ok

  let assert Ok(id) = process.receive(ref, 100)
  id |> should.equal(42)
}

// ---------------------------------------------------------------------------
// enviar — falha no envio
// ---------------------------------------------------------------------------

pub fn envio_com_sessao_fora_do_ar_nao_gasta_tentativa_test() {
  let ref = process.new_subject()
  let transacoes = transacao_capturar_erro(ref, 8)
  let mensageiro =
    MensageiroPorta(
      enviar: fn(_, _) {
        Error(erro.ErroComunicacao(
          "whatsmeow retornou status 503 [whatsapp_logged_out]: sessão removida",
        ))
      },
      enviar_citando: fn(_, _, _, _) { Ok(Nil) },
      reagir: fn(_, _, _, _) { Ok(Nil) },
    )

  let _ =
    entrega_auditada.enviar(
      fixtures.id("chat1@c.us"),
      transacao.RespostaTexto,
      "oi",
      mensageiro,
      transacoes,
    )

  let assert Ok(#(id, tentativas)) = process.receive(ref, 100)
  id |> should.equal(8)
  tentativas |> should.equal(0)
}

pub fn envio_falha_registra_erro_com_tentativa_test() {
  let ref = process.new_subject()
  let transacoes = transacao_capturar_erro(ref, 7)

  let _ =
    entrega_auditada.enviar(
      fixtures.id("chat1@c.us"),
      transacao.RespostaTexto,
      "oi",
      mensageiro_erro(),
      transacoes,
    )

  let assert Ok(#(id, tentativas)) = process.receive(ref, 100)
  id |> should.equal(7)
  tentativas |> should.equal(1)
}

pub fn envio_falha_propaga_erro_test() {
  entrega_auditada.enviar(
    fixtures.id("chat1@c.us"),
    transacao.RespostaTexto,
    "oi",
    mensageiro_erro(),
    transacao_sem_id(),
  )
  |> should.be_error
}

// ---------------------------------------------------------------------------
// enviar — falha no registro
// ---------------------------------------------------------------------------

pub fn falha_no_registro_envia_mesmo_assim_test() {
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
      foi_recebida: fn(_, _) { Ok(False) },
      marcar_recebida: fn(_, _) { Ok(Nil) },
    )

  // A resposta já foi paga: o banco ocupado não pode segurá-la.
  entrega_auditada.enviar(
    fixtures.id("chat1@c.us"),
    transacao.RespostaTexto,
    "oi",
    mensageiro_capturar_envio(enviou),
    transacoes,
  )
  |> should.be_ok

  process.receive(enviou, 50) |> should.equal(Ok(True))
}

// ---------------------------------------------------------------------------
// enviar — o que volta para quem chamou
// ---------------------------------------------------------------------------

pub fn falha_que_fica_na_fila_devolve_ok_test() {
  // A fila offline reenvia; um "tente novamente" geraria resposta duplicada.
  let ref = process.new_subject()
  entrega_auditada.enviar(
    fixtures.id("chat1@c.us"),
    transacao.RespostaIA,
    "resposta",
    mensageiro_erro(),
    transacao_capturar_erro(ref, 3),
  )
  |> should.be_ok
}

pub fn falha_definitiva_devolve_erro_test() {
  let mensageiro =
    MensageiroPorta(
      enviar: fn(_, _) {
        Error(erro.ErroComunicacao("telegram status 403: bot was blocked"))
      },
      enviar_citando: fn(_, _, _, _) { Ok(Nil) },
      reagir: fn(_, _, _, _) { Ok(Nil) },
    )
  let ref = process.new_subject()
  entrega_auditada.enviar(
    fixtures.id("chat1@c.us"),
    transacao.RespostaIA,
    "resposta",
    mensageiro,
    transacao_capturar_erro(ref, 4),
  )
  |> should.be_error
}

pub fn falha_sem_registro_devolve_erro_test() {
  let transacoes =
    TransacaoPorta(..transacao_sem_id(), registrar: fn(_) {
      Error(erro.ErroBancoDados("db offline"))
    })
  entrega_auditada.enviar(
    fixtures.id("chat1@c.us"),
    transacao.RespostaTexto,
    "oi",
    mensageiro_erro(),
    transacoes,
  )
  |> should.be_error
}

// ---------------------------------------------------------------------------
// enviar_citando — sucesso
// ---------------------------------------------------------------------------

pub fn envio_citando_sucesso_marca_entregue_test() {
  let ref = process.new_subject()
  let transacoes = transacao_capturar_id(ref, 55)

  entrega_auditada.enviar_citando(
    fixtures.id("chat1@c.us"),
    transacao.RespostaIA,
    "resposta",
    "MSG001",
    fixtures.id("user@c.us"),
    mensageiro_ok(),
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
      fixtures.id("chat1@c.us"),
      transacao.RespostaIA,
      "resposta",
      "MSG001",
      fixtures.id("user@c.us"),
      mensageiro_erro(),
      transacoes,
    )

  let assert Ok(#(id, tentativas)) = process.receive(ref, 100)
  id |> should.equal(9)
  tentativas |> should.equal(1)
}

// ---------------------------------------------------------------------------
// Resposta longa no Telegram: uma transação por parte
// ---------------------------------------------------------------------------

type EventoParte {
  Registrou(conteudo: String, id: Int)
  Enviou(texto: String, citando: Bool)
  Entregou(id: Int)
  Falhou(id: Int, tentativas: Int)
  Status(id: Int, status: transacao.StatusTransacao)
}

fn texto_em_tres_partes() -> String {
  // Parágrafos de 3000 caracteres: cada um vira uma parte.
  let paragrafo = fn(c) { string.repeat(c, 3000) }
  paragrafo("a") <> "\n\n" <> paragrafo("b") <> "\n\n" <> paragrafo("c")
}

fn transacoes_partes(ref: process.Subject(EventoParte)) -> TransacaoPorta {
  let contador = process.new_subject()
  process.send(contador, 100)
  TransacaoPorta(
    registrar: fn(tx) {
      let assert Ok(id) = process.receive(contador, 0)
      process.send(contador, id + 1)
      process.send(ref, Registrou(string.slice(tx.conteudo, 0, 1), id))
      Ok(transacao.Transacao(..tx, id: Some(id)))
    },
    atualizar_status: fn(id, status) {
      process.send(ref, Status(id, status))
      Ok(Nil)
    },
    atualizar_erro: fn(id, _, tentativas) {
      process.send(ref, Falhou(id, tentativas))
      Ok(Nil)
    },
    obter_pendentes: fn() { Ok([]) },
    obter_por_chat: fn(_) { Ok([]) },
    marcar_entregue: fn(id) {
      process.send(ref, Entregou(id))
      Ok(Nil)
    },
    limpar_antigas: fn() { Ok(Nil) },
    foi_recebida: fn(_, _) { Ok(False) },
    marcar_recebida: fn(_, _) { Ok(Nil) },
  )
}

fn mensageiro_partes(
  ref: process.Subject(EventoParte),
  falha_em: String,
  e: erro.Erro,
) -> MensageiroPorta {
  let enviar = fn(texto, citando) {
    process.send(ref, Enviou(string.slice(texto, 0, 1), citando))
    case string.starts_with(texto, falha_em) {
      True -> Error(e)
      False -> Ok(Nil)
    }
  }
  MensageiroPorta(
    enviar: fn(_, texto) { enviar(texto, False) },
    enviar_citando: fn(_, _, _, texto) { enviar(texto, True) },
    reagir: fn(_, _, _, _) { Ok(Nil) },
  )
}

fn eventos(ref: process.Subject(EventoParte), acc: List(EventoParte)) {
  case process.receive(ref, 20) {
    Ok(ev) -> eventos(ref, [ev, ..acc])
    Error(_) -> list.reverse(acc)
  }
}

pub fn resposta_longa_vira_uma_transacao_por_parte_test() {
  let ref = process.new_subject()
  entrega_auditada.enviar_citando(
    fixtures.id("tg:42"),
    transacao.RespostaIA,
    texto_em_tres_partes(),
    "7",
    fixtures.id("tg:42"),
    mensageiro_partes(ref, "nenhuma", erro.ErroComunicacao("x")),
    transacoes_partes(ref),
  )
  |> should.be_ok

  eventos(ref, [])
  |> should.equal([
    Registrou("a", 100),
    Registrou("b", 101),
    Registrou("c", 102),
    // Só a primeira cita a mensagem original.
    Enviou("a", True),
    Entregou(100),
    Enviou("b", False),
    Entregou(101),
    Enviou("c", False),
    Entregou(102),
  ])
}

pub fn parte_que_falha_fica_na_fila_com_as_seguintes_test() {
  // A parte "b" falha por erro passageiro: "a" já chegou e não é repetida;
  // "b" e "c" ficam registradas para a fila offline, nessa ordem.
  let ref = process.new_subject()
  entrega_auditada.enviar(
    fixtures.id("tg:42"),
    transacao.RespostaIA,
    texto_em_tres_partes(),
    mensageiro_partes(ref, "b", erro.ErroComunicacao("telegram status 502")),
    transacoes_partes(ref),
  )
  |> should.be_ok

  eventos(ref, [])
  |> list.drop(3)
  |> should.equal([
    Enviou("a", False),
    Entregou(100),
    Enviou("b", False),
    Falhou(101, 1),
  ])
}

pub fn parte_que_nao_vai_chegar_descarta_as_seguintes_test() {
  let ref = process.new_subject()
  entrega_auditada.enviar(
    fixtures.id("tg:42"),
    transacao.RespostaIA,
    texto_em_tres_partes(),
    mensageiro_partes(ref, "b", erro.ErroComunicacao("telegram status 403")),
    transacoes_partes(ref),
  )
  |> should.be_error

  eventos(ref, [])
  |> list.drop(5)
  |> should.equal([
    Enviou("b", False),
    Falhou(101, 1),
    Status(101, transacao.Descartada),
    // Sem a "b", a "c" deixaria um buraco no meio da resposta.
    Falhou(102, 0),
    Status(102, transacao.Descartada),
  ])
}
