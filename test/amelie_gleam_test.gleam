import amelie_gleam
import gleam/bytes_tree
import gleeunit
import gleeunit/should
import mist
import sqlight

pub fn main() {
  gleeunit.main()
}

pub fn tratar_health_retorna_json_com_status_test() {
  use conn <- sqlight.with_connection(":memory:")
  let resp =
    amelie_gleam.tratar_saude(conn, "http://localhost:59999", "fake-token")
  resp.status |> should.equal(200)
}

pub fn health_publico_nao_expoe_detalhes_test() {
  use conn <- sqlight.with_connection(":memory:")
  let resp = amelie_gleam.tratar_saude_publica(conn, "http://localhost:59999")
  resp.status |> should.equal(200)
  let assert mist.Bytes(corpo) = resp.body
  bytes_tree.to_bit_array(corpo)
  |> should.equal(<<"{\"status\":\"degraded\"}":utf8>>)
}
