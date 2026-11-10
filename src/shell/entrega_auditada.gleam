import core/privacidade
import dominio/erro.{type Erro}
import dominio/id_chat.{type IdChat}
import dominio/texto_partes
import dominio/transacao
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import logging
import portas/mensageiro_porta.{type MensageiroPorta}
import portas/transacao_porta.{type TransacaoPorta}
import shell/fila_offline
import shell/sistema

/// Envia a resposta e audita a entrega. Devolve Ok também quando o envio
/// falha mas a transação ficou na fila offline: a resposta vai chegar, e um
/// "tente novamente" faria o usuário pagar outra chamada de IA e receber duas
/// respostas. Error só quando a resposta não vai chegar.
///
/// Resposta maior que o limite do canal (Telegram) sai em partes, cada uma
/// com transação própria: se uma parte falhar, a fila offline reenvia dela
/// em diante, sem repetir o que já chegou.
pub fn enviar(
  chat_id: IdChat,
  tipo: transacao.TipoEntrega,
  conteudo: String,
  mensageiro: MensageiroPorta,
  transacoes: TransacaoPorta,
) -> Result(Nil, Erro) {
  entregar(chat_id, tipo, conteudo, mensageiro, transacoes, fn(parte) {
    mensageiro.enviar(chat_id, parte)
  })
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
  // Só a primeira parte cita a mensagem original.
  entregar(chat_id, tipo, conteudo, mensageiro, transacoes, fn(parte) {
    mensageiro.enviar_citando(chat_id, quoted_id, quoted_sender, parte)
  })
}

fn entregar(
  chat_id: IdChat,
  tipo: transacao.TipoEntrega,
  conteudo: String,
  mensageiro: MensageiroPorta,
  transacoes: TransacaoPorta,
  enviar_primeira: fn(String) -> Result(Nil, Erro),
) -> Result(Nil, Erro) {
  let partes = case id_chat.canal(chat_id) {
    id_chat.CanalTelegram ->
      texto_partes.dividir(conteudo, texto_partes.limite_telegram)
    _ -> [conteudo]
  }
  // Todas registradas antes do primeiro envio: se o envio parar no meio, o
  // resto já está na fila, na ordem.
  let registradas =
    list.map(partes, fn(parte) {
      #(parte, registrar(chat_id, tipo, parte, transacoes))
    })
  enviar_em_ordem(registradas, enviar_primeira, transacoes, fn(parte) {
    mensageiro.enviar(chat_id, parte)
  })
}

/// O registro é de melhor esforço: a resposta já foi paga, e um SQLite
/// ocupado não pode impedir que ela chegue. Sem registro, só não há reenvio.
fn registrar(
  chat_id: IdChat,
  tipo: transacao.TipoEntrega,
  conteudo: String,
  transacoes: TransacaoPorta,
) -> Option(transacao.Transacao) {
  case transacoes.registrar(transacao.novo(chat_id, tipo, conteudo)) {
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
}

fn enviar_em_ordem(
  itens: List(#(String, Option(transacao.Transacao))),
  enviar_parte: fn(String) -> Result(Nil, Erro),
  transacoes: TransacaoPorta,
  enviar_seguinte: fn(String) -> Result(Nil, Erro),
) -> Result(Nil, Erro) {
  case itens {
    [] -> Ok(Nil)
    [#(parte, registrada), ..resto] -> {
      let continuar = fn() {
        enviar_em_ordem(resto, enviar_seguinte, transacoes, enviar_seguinte)
      }
      case enviar_parte(parte), registrada {
        Ok(_), Some(tx) -> {
          // A parte já chegou; o que a falha aqui causa é um reenvio
          // duplicado pela fila offline, e o log permite diagnosticá-lo.
          marcar_entregue(transacoes, tx.id)
          |> sistema.registrar_falha(
            "EntregaAuditada: falha ao marcar transação como entregue; pode haver reenvio",
          )
          continuar()
        }
        Ok(_), None -> continuar()
        Error(e), None -> {
          descartar_resto(resto, transacoes)
          Error(e)
        }
        Error(e), Some(tx) ->
          case marcar_falha(transacoes, tx, e) {
            // As partes seguintes já estão registradas: a fila offline as
            // envia depois desta, na ordem.
            FicaNaFila -> Ok(Nil)
            NaoVaiChegar -> {
              descartar_resto(resto, transacoes)
              Error(e)
            }
          }
      }
    }
  }
}

/// Uma parte que não vai chegar invalida as seguintes: entregá-las sem ela
/// deixaria um buraco no meio da resposta.
fn descartar_resto(
  resto: List(#(String, Option(transacao.Transacao))),
  transacoes: TransacaoPorta,
) -> Nil {
  list.each(resto, fn(item) {
    case item.1 {
      Some(transacao.Transacao(id: Some(id), ..)) -> {
        transacoes.atualizar_erro(id, "parte anterior não foi entregue", 0)
        |> sistema.registrar_falha(
          "EntregaAuditada: falha ao registrar erro da parte descartada",
        )
        // Se falhar, a parte segue pendente e a fila pode enviá-la sem a
        // anterior: o log é o que permite diagnosticar o buraco.
        transacoes.atualizar_status(id, transacao.Descartada)
        |> sistema.registrar_falha(
          "EntregaAuditada: falha ao descartar parte seguinte",
        )
      }
      _ -> Nil
    }
  })
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
