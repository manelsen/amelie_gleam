import dominio/erro
import dominio/id_chat
import gleam/erlang/process
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import helpers/portas_fake
import portas/ponte_porta
import shell/avisos_ponte

pub fn aviso_de_volta_chega_ao_admin_test() {
  let caixa = process.new_subject()
  let admin = id_chat.telegram(42)
  avisos_ponte.avisar(
    ponte_porta.WhatsappVoltou,
    portas_fake.mensageiro_capturar(caixa),
    Some(admin),
  )
  |> should.equal(Ok(Nil))
  let assert Ok(#(destino, texto)) = process.receive(caixa, 100)
  destino |> should.equal(admin)
  string.contains(texto, "A Amélie voltou") |> should.be_true
}

pub fn sem_admin_o_evento_e_aceito_sem_envio_test() {
  let caixa = process.new_subject()
  avisos_ponte.avisar(
    ponte_porta.WhatsappCaiu("LoggedOut"),
    portas_fake.mensageiro_capturar(caixa),
    None,
  )
  |> should.equal(Ok(Nil))
  process.receive(caixa, 50) |> should.be_error
}

/// O erro sobe para o handler devolver 502 e a ponte tentar de novo.
pub fn falha_no_envio_e_propagada_test() {
  avisos_ponte.avisar(
    ponte_porta.WhatsappVoltou,
    portas_fake.mensageiro_erro(erro.ErroComunicacao("fora do ar")),
    Some(id_chat.telegram(42)),
  )
  |> should.be_error
}

pub fn texto_do_pareamento_traz_telefone_e_codigo_test() {
  let texto =
    avisos_ponte.texto(ponte_porta.CodigoPareamentoGerado("5531", "ABCD-EFGH"))
  string.contains(texto, "`+5531`") |> should.be_true
  string.contains(texto, "`ABCD-EFGH`") |> should.be_true
}

pub fn texto_da_queda_traz_o_motivo_test() {
  avisos_ponte.texto(ponte_porta.WhatsappCaiu("LoggedOut"))
  |> string.contains("Motivo: LoggedOut")
  |> should.be_true
}
