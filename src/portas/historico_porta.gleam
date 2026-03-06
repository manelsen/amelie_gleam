import dominio/erro.{type Erro}
import dominio/mensagem.{type Turno}

pub type HistoricoPorta {
  HistoricoPorta(
    obter: fn(String) -> Result(List(Turno), Erro),
    adicionar: fn(String, Turno) -> Result(Nil, Erro),
    limpar: fn(String) -> Result(Nil, Erro),
  )
}
