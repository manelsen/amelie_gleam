// Porta para persistência de usuários/chats vistos pela Amélie.

import dominio/erro.{type Erro}

pub type UsuarioPorta {
  UsuarioPorta(
    registrar: fn(String) -> Result(Nil, Erro),
    contar: fn() -> Result(Int, Erro),
    listar: fn() -> Result(List(String), Erro),
  )
}
