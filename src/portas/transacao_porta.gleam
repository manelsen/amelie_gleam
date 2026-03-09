import dominio/erro.{type Erro}
import dominio/transacao.{type StatusTransacao, type Transacao}

pub type TransacaoPorta {
  TransacaoPorta(
    registrar: fn(Transacao) -> Result(Transacao, Erro),
    atualizar_status: fn(Int, StatusTransacao) -> Result(Nil, Erro),
    atualizar_erro: fn(Int, String, Int) -> Result(Nil, Erro),
    obter_pendentes: fn() -> Result(List(Transacao), Erro),
    obter_por_chat: fn(String) -> Result(List(Transacao), Erro),
    marcar_entregue: fn(Int) -> Result(Nil, Erro),
  )
}
