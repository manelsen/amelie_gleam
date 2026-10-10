// shell/anti_spam.gleam
// Ator OTP que gerencia o estado in-memory de rate limiting e proteção contra spam.
// Supervisonado sob arvore_supervisao.gleam com auto-recuperação.

import core/anti_spam
import dominio/mensagem.{type Conteudo}
import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision
import gleam/result

const max_chats_em_memoria = 500

const ttl_inatividade_ms = 3_600_000

@external(erlang, "amelie_gleam_ffi", "now_ms")
fn now_ms() -> Int

pub type AntiSpam =
  Subject(MensagemAntiSpam)

pub type MensagemAntiSpam {
  Verificar(
    chat_id: String,
    remetente: String,
    peso: Float,
    agora_ms: Int,
    reply: Subject(anti_spam.DecisaoAntiSpam),
  )
  Desbloquear(chat_id: String, reply: Subject(Bool))
  ContarSilenciados(agora_ms: Int, reply: Subject(Int))
  LimpezaPeriodica(agora_ms: Int)
}

type Estado {
  Estado(dados: anti_spam.EstadoAntiSpam, admin_chat_id: String)
}

// ---------------------------------------------------------------------------
// Inicialização & Supervisão
// ---------------------------------------------------------------------------

pub fn iniciar(admin_chat_id: String) -> Result(AntiSpam, actor.StartError) {
  iniciar_actor(None, admin_chat_id)
  |> result.map(fn(started) { started.data })
}

pub fn iniciar_actor(
  name: Option(process.Name(MensagemAntiSpam)),
  admin_chat_id: String,
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
  admin_chat_id: String,
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
    Verificar(chat_id, remetente, peso, agora_ms, reply) -> {
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
      process.send(reply, decisao)
      actor.continue(Estado(..estado, dados: novos_dados))
    }

    Desbloquear(chat_id, reply) -> {
      let #(novos_dados, ok) = anti_spam.desbloquear(estado.dados, chat_id)
      process.send(reply, ok)
      actor.continue(Estado(..estado, dados: novos_dados))
    }

    ContarSilenciados(agora_ms, reply) -> {
      let count = anti_spam.contar_silenciados(estado.dados, agora_ms)
      process.send(reply, count)
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
  chat_id: String,
  remetente: String,
  corpo: Conteudo,
) -> anti_spam.DecisaoAntiSpam {
  let peso = anti_spam.peso_mensagem(corpo)
  let agora = now_ms()
  process.call(actor, 1000, fn(reply) {
    Verificar(chat_id, remetente, peso, agora, reply)
  })
}

pub fn desbloquear(actor: AntiSpam, chat_id: String) -> Bool {
  process.call(actor, 1000, fn(reply) { Desbloquear(chat_id, reply) })
}

pub fn contar_silenciados(actor: AntiSpam) -> Int {
  let agora = now_ms()
  process.call(actor, 1000, fn(reply) { ContarSilenciados(agora, reply) })
}
