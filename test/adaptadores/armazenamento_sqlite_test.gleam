import adaptadores/armazenamento_sqlite
import gleeunit/should
import sqlight

pub fn banco_aberto_responde_test() {
  use conn <- sqlight.with_connection(":memory:")
  armazenamento_sqlite.criar(conn).verificar() |> should.equal(Ok(Nil))
}
