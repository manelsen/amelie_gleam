import dominio/erro.{type Erro}
import dominio/id_chat.{type IdChat}
import dominio/mensagem.{type Turno}

pub type HistoricoPorta {
  HistoricoPorta(
    obter: fn(IdChat) -> Result(List(Turno), Erro),
    adicionar: fn(IdChat, Turno) -> Result(Nil, Erro),
    limpar: fn(IdChat) -> Result(Nil, Erro),
  )
}
