import dominio/erro.{type Erro}
import dominio/id_chat.{type IdChat}

pub type GrupoPorta {
  GrupoPorta(
    registrar: fn(IdChat, String) -> Result(Nil, Erro),
    listar: fn() -> Result(List(String), Erro),
  )
}
