import dominio/erro.{type Erro}
import dominio/id_chat.{type IdChat}
import dominio/transacao.{type StatusTransacao, type Transacao}

pub type TransacaoPorta {
  TransacaoPorta(
    registrar: fn(Transacao) -> Result(Transacao, Erro),
    atualizar_status: fn(Int, StatusTransacao) -> Result(Nil, Erro),
    atualizar_erro: fn(Int, String, Int) -> Result(Nil, Erro),
    obter_pendentes: fn() -> Result(List(Transacao), Erro),
    obter_por_chat: fn(IdChat) -> Result(List(Transacao), Erro),
    marcar_entregue: fn(Int) -> Result(Nil, Erro),
    limpar_antigas: fn() -> Result(Nil, Erro),
    // Rastreia mensagens recebidas para deduplicar (history sync).
    foi_recebida: fn(String) -> Result(Bool, Erro),
    marcar_recebida: fn(String) -> Result(Nil, Erro),
  )
}
