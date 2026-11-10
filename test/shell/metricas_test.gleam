import dominio/acao.{MidiaAudio}
import gleam/erlang/process
import gleam/option.{None}
import gleeunit/should
import shell/metricas

pub fn registrar_sem_ator_no_nome_nao_derruba_quem_conta_test() {
  // Nome sem dono, como durante o reinício do ator: antes, panic.
  let metricas = process.named_subject(process.new_name("metricas_ausente"))
  metricas.registrar(metricas, metricas.MidiaPorTipo(MidiaAudio))
  |> should.equal(Nil)
}

pub fn registrar_com_ator_vivo_conta_test() {
  let assert Ok(iniciado) = metricas.iniciar_actor(None)
  metricas.registrar(iniciado.data, metricas.MidiaPorTipo(MidiaAudio))
  metricas.consultar(iniciado.data).audios |> should.equal(1)
}
