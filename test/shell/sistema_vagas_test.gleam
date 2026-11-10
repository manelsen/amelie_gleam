import gleam/erlang/process
import gleam/list
import gleeunit/should
import shell/sistema

pub fn vagas_respeitam_o_teto_e_voltam_ao_liberar_test() {
  let nome = "teste_vagas"
  sistema.reservar_vaga(nome, 2) |> should.be_true
  sistema.reservar_vaga(nome, 2) |> should.be_true
  sistema.reservar_vaga(nome, 2) |> should.be_false
  sistema.liberar_vaga(nome)
  sistema.reservar_vaga(nome, 2) |> should.be_true
  sistema.liberar_vaga(nome)
  sistema.liberar_vaga(nome)
}

pub fn tentativa_sem_vaga_nao_ocupa_vaga_test() {
  // Recusas seguidas não podem deixar o contador acima do teto.
  let nome = "teste_vagas_cas"
  sistema.reservar_vaga(nome, 1) |> should.be_true
  sistema.reservar_vaga(nome, 1) |> should.be_false
  sistema.reservar_vaga(nome, 1) |> should.be_false
  sistema.liberar_vaga(nome)
  sistema.reservar_vaga(nome, 1) |> should.be_true
  sistema.liberar_vaga(nome)
}

pub fn primeiras_reservas_simultaneas_usam_o_mesmo_contador_test() {
  // Muitas primeiras reservas ao mesmo tempo: todas precisam cair no mesmo
  // contador, senão o teto vale por contador e não por nome.
  let nome = "teste_vagas_corrida"
  let quem_responde = process.new_subject()
  list.repeat(Nil, 50)
  |> list.each(fn(_) {
    process.spawn(fn() {
      process.send(quem_responde, sistema.reservar_vaga(nome, 10))
    })
  })
  let aceitas =
    list.repeat(Nil, 50)
    |> list.map(fn(_) {
      let assert Ok(aceita) = process.receive(quem_responde, 5000)
      aceita
    })
    |> list.count(fn(aceita) { aceita })
  aceitas |> should.equal(10)
  sistema.reservar_vaga(nome, 10) |> should.be_false
  list.repeat(Nil, 10) |> list.each(fn(_) { sistema.liberar_vaga(nome) })
}
