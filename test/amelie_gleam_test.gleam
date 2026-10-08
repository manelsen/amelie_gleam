import amelie_gleam
import gleeunit
import gleeunit/should
import sqlight

pub fn main() {
  gleeunit.main()
}

pub fn handle_health_retorna_json_com_status_test() {
  use conn <- sqlight.with_connection(":memory:")
  let resp =
    amelie_gleam.handle_health(conn, "http://localhost:59999", "fake-token")
  resp.status |> should.equal(200)
}
