import dominio/erro.{type Erro}

pub type GrupoPorta {
  GrupoPorta(
    registrar: fn(String, String) -> Result(Nil, Erro),
    listar: fn() -> Result(List(String), Erro),
  )
}
