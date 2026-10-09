import dominio/erro
import gleam/erlang/process
import gleeunit/should
import helpers/portas_fake
import portas/transacao_porta.{TransacaoPorta}
import shell/manutencao

pub fn manutencao_executar_chama_limpeza_transacoes_test() {
  let ref = process.new_subject()
  let porta_base = portas_fake.transacao_noop()
  let porta =
    TransacaoPorta(..porta_base, limpar_antigas: fn() {
      process.send(ref, "limpeza_chamada")
      Ok(Nil)
    })

  manutencao.executar(porta)

  process.receive(ref, 1000)
  |> should.equal(Ok("limpeza_chamada"))
}

pub fn manutencao_executar_com_erro_banco_nao_entra_em_panico_test() {
  let porta_base = portas_fake.transacao_noop()
  let porta =
    TransacaoPorta(..porta_base, limpar_antigas: fn() {
      Error(erro.ErroBancoDados("falha de teste"))
    })

  // Deve concluir sem lançar exceção / pânico
  manutencao.executar(porta)
  |> should.equal(Nil)
}
