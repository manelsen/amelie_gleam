// core/anti_spam.gleam
// Lógica pura de rate limiting por token bucket e mitigação progressiva de spam.
// Totalmente determinística: recebe estado e timestamps, retorna novo estado e decisão.

import dominio/mensagem.{type Conteudo}
import gleam/dict.{type Dict}
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}

// ---------------------------------------------------------------------------
// Constantes de calibração
// ---------------------------------------------------------------------------

/// Capacidade máxima do balde de tokens (margem de rajada para conversação natural).
pub const max_tokens: Float = 4.0

/// Taxa de recarga: 1 token a cada 12 segundos (~0.0833 tokens/s).
pub const recarga_por_segundo: Float = 0.08333333333333333

/// Janela para detecção de rajada de flood: 5 mensagens em até 3 segundos.
pub const janela_flood_ms: Int = 3000

/// Quantidade de mensagens dentro da janela que caracteriza flood automatizado.
pub const limite_msgs_flood: Int = 5

/// Cooldown do Strike 1: 30 segundos de pausa após esgotar tokens normais.
pub const cooldown_strike1_ms: Int = 30_000

/// Cooldown do Strike 2: 5 minutos de pausa após reincidência durante cooldown.
pub const cooldown_strike2_ms: Int = 300_000

/// Quarentena do Strike 3: 30 minutos de silenciamento total (blackhole).
pub const quarentena_strike3_ms: Int = 1_800_000

/// Tempo de inatividade após o qual os strikes de um usuário são perdoados (10 min).
pub const perdao_strikes_inatividade_ms: Int = 600_000

// ---------------------------------------------------------------------------
// Tipos de Domínio
// ---------------------------------------------------------------------------

pub type DecisaoAntiSpam {
  /// Mensagem aceita para processamento.
  Permitido
  /// Limite de taxa atingido. Deve responder ao usuário com o aviso explicativo.
  AvisoLimite(motivo: String)
  /// Usuário em quarentena/jail. Deve descartar silenciosamente (blackhole).
  /// Se `Some(alerta)`, Amélie deve encaminhar o alerta ao administrador.
  Silenciado(notificar_admin: Option(String))
}

pub type RegistroChat {
  RegistroChat(
    tokens: Float,
    ultimo_ts_ms: Int,
    strikes: Int,
    quarentena_ate_ms: Int,
    recentes_ts: List(Int),
  )
}

pub type EstadoAntiSpam =
  Dict(String, RegistroChat)

pub fn novo_estado() -> EstadoAntiSpam {
  dict.new()
}

// ---------------------------------------------------------------------------
// Cálculo de peso por tipo de mídia
// ---------------------------------------------------------------------------

/// Atribui peso maior para mídias pesadas (vídeo, áudio) para proteger CPU/IA.
pub fn peso_mensagem(corpo: Conteudo) -> Float {
  case corpo {
    mensagem.Video(..) -> 3.0
    mensagem.Audio(..) -> 2.0
    mensagem.Imagem(..) -> 2.0
    mensagem.Documento(..) -> 2.0
    mensagem.Sticker(..) -> 1.5
    _ -> 1.0
  }
}

// ---------------------------------------------------------------------------
// Avaliação principal (Pura)
// ---------------------------------------------------------------------------

pub fn avaliar(
  estado: EstadoAntiSpam,
  chat_id: String,
  remetente: String,
  admin_chat_id: String,
  peso: Float,
  agora_ms: Int,
) -> #(EstadoAntiSpam, DecisaoAntiSpam) {
  // 1. Isenção total para o administrador do bot
  let eh_admin =
    admin_chat_id != ""
    && {
      chat_id == admin_chat_id
      || chat_id == "tg:" <> admin_chat_id
      || remetente == admin_chat_id
      || remetente == "tg:" <> admin_chat_id
    }

  case eh_admin {
    True -> #(estado, Permitido)
    False -> {
      let reg = case dict.get(estado, chat_id) {
        Ok(r) -> r
        Error(_) ->
          RegistroChat(
            tokens: max_tokens,
            ultimo_ts_ms: agora_ms,
            strikes: 0,
            quarentena_ate_ms: 0,
            recentes_ts: [],
          )
      }

      // 2. Verificar se o chat está sob cooldown/quarentena ativa
      case agora_ms < reg.quarentena_ate_ms {
        True -> avaliar_em_quarentena(estado, chat_id, reg, agora_ms)
        False -> avaliar_livre(estado, chat_id, reg, peso, agora_ms)
      }
    }
  }
}

fn avaliar_em_quarentena(
  estado: EstadoAntiSpam,
  chat_id: String,
  reg: RegistroChat,
  agora_ms: Int,
) -> #(EstadoAntiSpam, DecisaoAntiSpam) {
  case reg.strikes >= 3 {
    // Já está no Strike 3 (Quarentena/Blackhole): descarte silencioso sem notificar de novo.
    True -> {
      let novo_reg = RegistroChat(..reg, ultimo_ts_ms: agora_ms)
      #(dict.insert(estado, chat_id, novo_reg), Silenciado(None))
    }
    // Reincidência durante Strike 2 (timeout de 5 min) -> escala para Strike 3 (Jail 30m)
    False ->
      case reg.strikes == 2 {
        True -> {
          let alerta =
            "🚨 *[Anti-Spam] Chat silenciado por 30m por reincidência durante timeout*\n"
            <> "• Chat: `"
            <> chat_id
            <> "`\n"
            <> "• Ação: Quarentena ativada."
          let novo_reg =
            RegistroChat(
              ..reg,
              strikes: 3,
              quarentena_ate_ms: agora_ms + quarentena_strike3_ms,
              ultimo_ts_ms: agora_ms,
            )
          #(dict.insert(estado, chat_id, novo_reg), Silenciado(Some(alerta)))
        }
        // Reincidência durante Strike 1 (cooldown de 30s) -> escala para Strike 2 (Timeout 5m)
        False -> {
          let aviso =
            "⚠️ Muitas mensagens durante o tempo de espera. Seu chat foi pausado por 5 minutos."
          let novo_reg =
            RegistroChat(
              ..reg,
              strikes: 2,
              quarentena_ate_ms: agora_ms + cooldown_strike2_ms,
              ultimo_ts_ms: agora_ms,
            )
          #(dict.insert(estado, chat_id, novo_reg), AvisoLimite(aviso))
        }
      }
  }
}

fn avaliar_livre(
  estado: EstadoAntiSpam,
  chat_id: String,
  reg: RegistroChat,
  peso: Float,
  agora_ms: Int,
) -> #(EstadoAntiSpam, DecisaoAntiSpam) {
  // Perdão de strikes após período longo de bom comportamento
  let strikes_atuais = case
    agora_ms - reg.ultimo_ts_ms > perdao_strikes_inatividade_ms
  {
    True -> 0
    False -> reg.strikes
  }

  // 3. Detecção de rajada de flood volumétrico (> 5 msgs em 3s)
  let recentes_filtrados =
    list.filter(reg.recentes_ts, fn(ts) { agora_ms - ts <= janela_flood_ms })
  let novos_recentes = [agora_ms, ..recentes_filtrados]

  case list.length(novos_recentes) >= limite_msgs_flood {
    True -> {
      // Disparo imediato de flood automatizado -> pula direto para Strike 3
      let alerta =
        "🚨 *[Anti-Spam] Chat silenciado por 30m por flood volumétrico*\n"
        <> "• Chat: `"
        <> chat_id
        <> "`\n"
        <> "• Motivo: Mais de 5 mensagens em 3 segundos."
      let novo_reg =
        RegistroChat(
          tokens: 0.0,
          ultimo_ts_ms: agora_ms,
          strikes: 3,
          quarentena_ate_ms: agora_ms + quarentena_strike3_ms,
          recentes_ts: novos_recentes,
        )
      #(dict.insert(estado, chat_id, novo_reg), Silenciado(Some(alerta)))
    }

    False -> {
      // 4. Token Bucket convencional
      let delta_s =
        float.max(0.0, int.to_float(agora_ms - reg.ultimo_ts_ms) /. 1000.0)
      let tokens_recarregados =
        float.min(max_tokens, reg.tokens +. delta_s *. recarga_por_segundo)

      case tokens_recarregados >=. peso {
        True -> {
          let novo_reg =
            RegistroChat(
              tokens: tokens_recarregados -. peso,
              ultimo_ts_ms: agora_ms,
              strikes: strikes_atuais,
              quarentena_ate_ms: 0,
              recentes_ts: novos_recentes,
            )
          #(dict.insert(estado, chat_id, novo_reg), Permitido)
        }

        False -> {
          // Esgotou tokens -> Aplica Strike 1 com cooldown de 30s
          let aviso = case peso >=. 3.0 {
            True ->
              "⏳ Calma lá! Mídias pesadas demandam mais tempo para processar. Por favor, aguarde 30 segundos antes de enviar outra."
            False ->
              "⏳ Calma lá! Muitas mensagens seguidas. Por favor, aguarde 30 segundos antes de enviar outra."
          }
          let novo_reg =
            RegistroChat(
              tokens: 0.0,
              ultimo_ts_ms: agora_ms,
              strikes: int.max(1, strikes_atuais + 1),
              quarentena_ate_ms: agora_ms + cooldown_strike1_ms,
              recentes_ts: novos_recentes,
            )
          #(dict.insert(estado, chat_id, novo_reg), AvisoLimite(aviso))
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Comandos e Gestão de Estado
// ---------------------------------------------------------------------------

pub fn desbloquear(
  estado: EstadoAntiSpam,
  chat_id: String,
) -> #(EstadoAntiSpam, Bool) {
  case dict.has_key(estado, chat_id) {
    True -> #(dict.delete(estado, chat_id), True)
    False -> #(estado, False)
  }
}

pub fn contar_silenciados(estado: EstadoAntiSpam, agora_ms: Int) -> Int {
  dict.fold(estado, 0, fn(acc, _chat_id, reg) {
    case agora_ms < reg.quarentena_ate_ms && reg.strikes >= 3 {
      True -> acc + 1
      False -> acc
    }
  })
}

pub fn limpar_inativos(
  estado: EstadoAntiSpam,
  agora_ms: Int,
  ttl_inatividade_ms: Int,
) -> EstadoAntiSpam {
  dict.filter(estado, fn(_k, reg) {
    agora_ms < reg.quarentena_ate_ms
    || agora_ms - reg.ultimo_ts_ms < ttl_inatividade_ms
  })
}
