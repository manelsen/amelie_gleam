import dominio/erro.{type Erro}
import dominio/transacao
import gleam/option
import gleam/result
import portas/transacao_porta.{type TransacaoPorta}
import portas/whatsapp_porta.{type WhatsappPorta}

pub fn enviar(
  chat_id: String,
  remetente: String,
  tipo: String,
  conteudo: String,
  whatsapp: WhatsappPorta,
  transacoes: TransacaoPorta,
) -> Result(Nil, Erro) {
  let tx = transacao.novo(chat_id, remetente, tipo, conteudo)
  use registrada <- result.try(transacoes.registrar(tx))

  case whatsapp.enviar(chat_id, conteudo) {
    Ok(_) -> {
      let _ = marcar_entregue(transacoes, registrada.id)
      Ok(Nil)
    }
    Error(e) -> {
      let _ = marcar_falha(transacoes, registrada, e)
      Error(e)
    }
  }
}

pub fn enviar_citando(
  chat_id: String,
  remetente: String,
  tipo: String,
  conteudo: String,
  quoted_id: String,
  quoted_sender: String,
  whatsapp: WhatsappPorta,
  transacoes: TransacaoPorta,
) -> Result(Nil, Erro) {
  let tx = transacao.novo(chat_id, remetente, tipo, conteudo)
  use registrada <- result.try(transacoes.registrar(tx))

  case whatsapp.enviar_citando(chat_id, quoted_id, quoted_sender, conteudo) {
    Ok(_) -> {
      let _ = marcar_entregue(transacoes, registrada.id)
      Ok(Nil)
    }
    Error(e) -> {
      let _ = marcar_falha(transacoes, registrada, e)
      Error(e)
    }
  }
}

fn marcar_entregue(
  transacoes: TransacaoPorta,
  tx_id: option.Option(Int),
) -> Result(Nil, Erro) {
  case tx_id {
    option.Some(id) -> transacoes.marcar_entregue(id)
    option.None -> Ok(Nil)
  }
}

fn marcar_falha(
  transacoes: TransacaoPorta,
  tx: transacao.Transacao,
  e: Erro,
) -> Result(Nil, Erro) {
  case tx.id {
    option.Some(id) ->
      transacoes.atualizar_erro(id, erro.descricao(e), tx.tentativas + 1)
    option.None -> Ok(Nil)
  }
}
