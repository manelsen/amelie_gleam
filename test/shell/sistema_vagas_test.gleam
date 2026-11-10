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
