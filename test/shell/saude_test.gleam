import gleam/string
import gleeunit/should
import helpers/portas_fake
import portas/armazenamento_porta.{ArmazenamentoPorta}
import portas/ponte_porta.{StatusPonte}
import shell/saude

fn banco_ok() {
  ArmazenamentoPorta(verificar: fn() { Ok(Nil) })
}

fn banco_fora() {
  ArmazenamentoPorta(verificar: fn() { Error("disk I/O error") })
}

pub fn saude_detalhada_com_tudo_no_ar_test() {
  let #(codigo, corpo) =
    saude.detalhada(
      banco_ok(),
      portas_fake.ponte_com_status(StatusPonte(conectado: True, logado: True)),
      True,
    )
  codigo |> should.equal(200)
  string.starts_with(corpo, "{\"status\":\"ok\"") |> should.be_true
  string.contains(corpo, "\"enabled\":true") |> should.be_true
}

pub fn saude_detalhada_com_ponte_fora_fica_degradada_test() {
  let #(codigo, corpo) =
    saude.detalhada(banco_ok(), portas_fake.ponte_inacessivel(), False)
  codigo |> should.equal(200)
  string.starts_with(corpo, "{\"status\":\"degraded\"") |> should.be_true
  string.contains(corpo, "\"status\":\"unreachable\"") |> should.be_true
  string.contains(corpo, "\"enabled\":false") |> should.be_true
}

pub fn saude_detalhada_com_banco_fora_da_503_e_mostra_o_erro_test() {
  let #(codigo, corpo) =
    saude.detalhada(banco_fora(), portas_fake.ponte_inacessivel(), True)
  codigo |> should.equal(503)
  string.starts_with(corpo, "{\"status\":\"error\"") |> should.be_true
  string.contains(corpo, "disk I/O error") |> should.be_true
}

pub fn saude_publica_nao_expoe_detalhes_test() {
  saude.publica(banco_ok(), portas_fake.ponte_inacessivel())
  |> should.equal(#(200, "{\"status\":\"degraded\"}"))
  saude.publica(
    banco_ok(),
    portas_fake.ponte_com_status(StatusPonte(conectado: True, logado: True)),
  )
  |> should.equal(#(200, "{\"status\":\"ok\"}"))
  saude.publica(banco_fora(), portas_fake.ponte_inacessivel())
  |> should.equal(#(503, "{\"status\":\"error\"}"))
}
