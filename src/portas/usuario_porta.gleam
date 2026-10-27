// Porta para persistência de usuários/chats vistos pela Amélie.

import dominio/erro.{type Erro}
import dominio/id_chat.{type IdChat}

pub type UsuarioPorta {
  UsuarioPorta(
    registrar: fn(IdChat) -> Result(Nil, Erro),
    contar: fn() -> Result(Int, Erro),
    listar: fn() -> Result(List(IdChat), Erro),
  )
}
