// Testes da fila serial de mensagens atrasadas.

import gleam/erlang/process
import gleam/list
import gleam/option.{None}
import gleeunit/should
import shell/fila_atrasadas

pub fn e_atrasada_test() {
  let agora = 1_000_000
  fila_atrasadas.e_atrasada(agora, agora) |> should.be_false
  fila_atrasadas.e_atrasada(agora - fila_atrasadas.limiar_atraso_s, agora)
  |> should.be_false
  fila_atrasadas.e_atrasada(agora - fila_atrasadas.limiar_atraso_s - 1, agora)
  |> should.be_true
  // Sem horário de envio, não dá para dizer que atrasou.
  fila_atrasadas.e_atrasada(0, agora) |> should.be_false
}

type Evento {
  Inicio(Int)
  Fim(Int)
}

fn coletar(ref: process.Subject(Evento), n: Int) -> List(Evento) {
  list.repeat(Nil, n)
  |> list.map(fn(_) {
    let assert Ok(evento) = process.receive(ref, 1000)
    evento
  })
}

pub fn processa_uma_por_vez_na_ordem_test() {
  let ref = process.new_subject()
  let assert Ok(fila) = fila_atrasadas.iniciar()

  list.each([1, 2, 3], fn(i) {
    fila_atrasadas.enfileirar(fila, fn() {
      process.send(ref, Inicio(i))
      process.sleep(20)
      process.send(ref, Fim(i))
    })
  })

  coletar(ref, 6)
  |> should.equal([Inicio(1), Fim(1), Inicio(2), Fim(2), Inicio(3), Fim(3)])
}

pub fn tarefa_que_quebra_nao_para_a_fila_test() {
  let ref = process.new_subject()
  let assert Ok(fila) = fila_atrasadas.iniciar()

  fila_atrasadas.enfileirar(fila, fn() { panic as "falha simulada" })
  fila_atrasadas.enfileirar(fila, fn() { process.send(ref, Fim(2)) })

  coletar(ref, 1) |> should.equal([Fim(2)])
}

pub fn tarefa_travada_e_encerrada_no_tempo_maximo_test() {
  let ref = process.new_subject()
  let assert Ok(iniciada) = fila_atrasadas.iniciar_actor(None, 50)
  let fila = iniciada.data

  fila_atrasadas.enfileirar(fila, fn() {
    process.sleep(10_000)
    process.send(ref, Fim(1))
  })
  fila_atrasadas.enfileirar(fila, fn() { process.send(ref, Fim(2)) })

  coletar(ref, 1) |> should.equal([Fim(2)])
}
