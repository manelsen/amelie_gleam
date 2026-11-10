import core/privacidade
import dominio/erro.{type Erro}
import dominio/id_chat.{type IdChat}
import dominio/transacao
import gleam/int
import gleam/option.{None, Some}
import logging
import portas/mensageiro_porta.{type MensageiroPorta}
import portas/transacao_porta.{type TransacaoPorta}
import shell/fila_offline

/// Envia a resposta e audita a entrega. Devolve Ok também quando o envio
/// falha mas a transação ficou na fila offline: a resposta vai chegar, e um
/// "tente novamente" faria o usuário pagar outra chamada de IA e receber duas
/// respostas. Error só quando a resposta não vai chegar.
pub fn enviar(
  chat_id: IdChat,
  tipo: transacao.TipoEntrega,
  conteudo: String,
  mensageiro: MensageiroPorta,
  transacoes: TransacaoPorta,
) -> Result(Nil, Erro) {
  use <- auditar(chat_id, tipo, conteudo, transacoes)
  mensageiro.enviar(chat_id, conteudo)
}

pub fn enviar_citando(
  chat_id: IdChat,
  tipo: transacao.TipoEntrega,
  conteudo: String,
  quoted_id: String,
  quoted_sender: IdChat,
  mensageiro: MensageiroPorta,
  transacoes: TransacaoPorta,
) -> Result(Nil, Erro) {
  use <- auditar(chat_id, tipo, conteudo, transacoes)
  mensageiro.enviar_citando(chat_id, quoted_id, quoted_sender, conteudo)
}

fn auditar(
  chat_id: IdChat,
  tipo: transacao.TipoEntrega,
  conteudo: String,
  transacoes: TransacaoPorta,
  envio: fn() -> Result(Nil, Erro),
) -> Result(Nil, Erro) {
  // O registro é de melhor esforço: a resposta já foi paga, e um SQLite
  // ocupado não pode impedir que ela chegue. Sem registro, só não há reenvio.
  let registrada = case
    transacoes.registrar(transacao.novo(chat_id, tipo, conteudo))
  {
    Ok(tx) -> Some(tx)
    Error(e) -> {
      logging.log(
        logging.Warning,
        "EntregaAuditada: falha ao registrar transação para "
          <> privacidade.mascarar(chat_id)
          <> "; enviando sem auditoria: "
          <> erro.descricao(e),
      )
      None
    }
  }

  case envio(), registrada {
    Ok(_), Some(tx) -> {
      let _ = marcar_entregue(transacoes, tx.id)
      Ok(Nil)
    }
    Ok(_), None -> Ok(Nil)
    Error(e), None -> Error(e)
    Error(e), Some(tx) ->
      case marcar_falha(transacoes, tx, e) {
        FicaNaFila -> Ok(Nil)
        NaoVaiChegar -> Error(e)
      }
  }
}

type DestinoFalha {
  FicaNaFila
  NaoVaiChegar
}

fn marcar_entregue(
  transacoes: TransacaoPorta,
  tx_id: option.Option(Int),
) -> Result(Nil, Erro) {
  case tx_id {
    Some(id) -> transacoes.marcar_entregue(id)
    None -> Ok(Nil)
  }
}

fn marcar_falha(
  transacoes: TransacaoPorta,
  tx: transacao.Transacao,
  e: Erro,
) -> DestinoFalha {
  case tx.id {
    Some(id) -> {
      case fila_offline.e_erro_sessao(e), fila_offline.e_erro_definitivo(e) {
        // Sessão fora do ar: fica pendente, sem gastar tentativa, até a
        // fila offline ver a sessão de volta.
        True, _ -> {
          logging.log(
            logging.Info,
            "EntregaAuditada: transação "
              <> int.to_string(id)
              <> " aguardando a sessão do WhatsApp: "
              <> erro.descricao(e),
          )
          let _ =
            transacoes.atualizar_erro(id, erro.descricao(e), tx.tentativas)
          FicaNaFila
        }
        _, True -> {
          let _ =
            transacoes.atualizar_erro(
              id,
              erro.descricao(e) <> " (descarte definitivo)",
              tx.tentativas + 1,
            )
          let _ = transacoes.atualizar_status(id, transacao.Descartada)
          logging.log(
            logging.Warning,
            "EntregaAuditada: transação "
              <> int.to_string(id)
              <> " descartada imediatamente por erro definitivo: "
              <> erro.descricao(e),
          )
          NaoVaiChegar
        }
        _, False -> {
          // Mesmo que atualizar_erro falhe, a linha continua pendente e a
          // fila offline a encontra.
          let _ =
            transacoes.atualizar_erro(id, erro.descricao(e), tx.tentativas + 1)
          FicaNaFila
        }
      }
    }
    None -> NaoVaiChegar
  }
}
