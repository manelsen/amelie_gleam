import gleam/erlang/process
import gleeunit/should
import shell/ator_vivo

pub fn nome_sem_dono_nao_gera_panic_test() {
  let sem_dono = process.named_subject(process.new_name("ator_ausente"))
  ator_vivo.enviar(sem_dono, "oi") |> should.be_false
}

pub fn subject_comum_recebe_test() {
  let subject = process.new_subject()
  ator_vivo.enviar(subject, "oi") |> should.be_true
  process.receive(subject, 100) |> should.equal(Ok("oi"))
}

pub fn nome_com_dono_recebe_pelo_nome_test() {
  // A mensagem chega no formato de um envio pelo nome: quem recebe com o
  // subject nomeado a reconhece.
  let nome = process.new_name("ator_presente")
  let assert Ok(Nil) = process.register(process.self(), nome)
  let subject = process.named_subject(nome)
  ator_vivo.enviar(subject, "oi") |> should.be_true
  process.receive(subject, 100) |> should.equal(Ok("oi"))
  let _ = process.unregister(nome)
  Nil
}
