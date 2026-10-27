// shell/anti_spam.gleam
// Ator OTP que gerencia o estado in-memory de rate limiting e proteção contra spam.
// Supervisonado sob arvore_supervisao.gleam com auto-recuperação.

import core/anti_spam
import dominio/id_chat.{type IdChat}
import dominio/mensagem.{type Conteudo}
import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision
import gleam/result
import shell/sistema

const max_chats_em_memoria = 500

const ttl_inatividade_ms = 3_600_000

pub type AntiSpam =
  Subject(MensagemAntiSpam)

pub type MensagemAntiSpam {
  Verificar(
    chat_id: IdChat,
    remetente: IdChat,
    peso: Float,
    agora_ms: Int,
    resposta: Subject(anti_spam.DecisaoAntiSpam),
  )
  Desbloquear(alvo: String, resposta: Subject(Bool))
  ContarSilenciados(agora_ms: Int, resposta: Subject(Int))
  LimpezaPeriodica(agora_ms: Int)
}

type Estado {
  Estado(dados: anti_spam.EstadoAntiSpam, admin_chat_id: Option(IdChat))
}

// ---------------------------------------------------------------------------
// Inicialização & Supervisão
// ---------------------------------------------------------------------------

pub fn iniciar(
  admin_chat_id: Option(IdChat),
) -> Result(AntiSpam, actor.StartError) {
  iniciar_actor(None, admin_chat_id)
  |> result.map(fn(started) { started.data })
}

pub fn iniciar_actor(
  name: Option(process.Name(MensagemAntiSpam)),
  admin_chat_id: Option(IdChat),
) -> Result(actor.Started(AntiSpam), actor.StartError) {
  let builder =
    actor.new(Estado(
      dados: anti_spam.novo_estado(),
      admin_chat_id: admin_chat_id,
    ))
    |> actor.on_message(tratar)

  let builder = case name {
    Some(n) -> actor.named(builder, n)
    None -> builder
  }

  actor.start(builder)
}

pub fn supervisionado(
  name: process.Name(MensagemAntiSpam),
  admin_chat_id: Option(IdChat),
) -> supervision.ChildSpecification(AntiSpam) {
  supervision.worker(fn() { iniciar_actor(Some(name), admin_chat_id) })
}

// ---------------------------------------------------------------------------
// Loop do Ator
// ---------------------------------------------------------------------------

fn tratar(
  estado: Estado,
  msg: MensagemAntiSpam,
) -> actor.Next(Estado, MensagemAntiSpam) {
  case msg {
    Verificar(chat_id, remetente, peso, agora_ms, resposta) -> {
      // Poda proativa se o dicionário exceder limite de capacidade
      let dados_atuais = case dict.size(estado.dados) >= max_chats_em_memoria {
        True ->
          anti_spam.limpar_inativos(estado.dados, agora_ms, ttl_inatividade_ms)
        False -> estado.dados
      }

      let #(novos_dados, decisao) =
        anti_spam.avaliar(
          dados_atuais,
          chat_id,
          remetente,
          estado.admin_chat_id,
          peso,
          agora_ms,
        )
      process.send(resposta, decisao)
      actor.continue(Estado(..estado, dados: novos_dados))
    }

    Desbloquear(alvo, resposta) -> {
      let #(novos_dados, ok) = anti_spam.desbloquear(estado.dados, alvo)
      process.send(resposta, ok)
      actor.continue(Estado(..estado, dados: novos_dados))
    }

    ContarSilenciados(agora_ms, resposta) -> {
      let count = anti_spam.contar_silenciados(estado.dados, agora_ms)
      process.send(resposta, count)
      actor.continue(estado)
    }

    LimpezaPeriodica(agora_ms) -> {
      let novos_dados =
        anti_spam.limpar_inativos(estado.dados, agora_ms, ttl_inatividade_ms)
      actor.continue(Estado(..estado, dados: novos_dados))
    }
  }
}

// ---------------------------------------------------------------------------
// Funções de Conveniência (Client API)
// ---------------------------------------------------------------------------

pub fn verificar(
  actor: AntiSpam,
  chat_id: IdChat,
  remetente: IdChat,
  corpo: Conteudo,
) -> anti_spam.DecisaoAntiSpam {
  let peso = anti_spam.peso_mensagem(corpo)
  let agora = sistema.agora_ms()
  process.call(actor, 1000, fn(resposta) {
    Verificar(chat_id, remetente, peso, agora, resposta)
  })
}

pub fn desbloquear(actor: AntiSpam, alvo: String) -> Bool {
  process.call(actor, 1000, fn(resposta) { Desbloquear(alvo, resposta) })
}

pub fn contar_silenciados(actor: AntiSpam) -> Int {
  let agora = sistema.agora_ms()
  process.call(actor, 1000, fn(resposta) { ContarSilenciados(agora, resposta) })
}
