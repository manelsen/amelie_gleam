//// Saúde do SQLite: uma consulta trivial confirma que a conexão responde.

import portas/armazenamento_porta.{type ArmazenamentoPorta, ArmazenamentoPorta}
import sqlight

pub fn criar(conn: sqlight.Connection) -> ArmazenamentoPorta {
  ArmazenamentoPorta(verificar: fn() {
    case sqlight.exec("SELECT 1;", conn) {
      Ok(_) -> Ok(Nil)
      Error(err) -> Error(err.message)
    }
  })
}
