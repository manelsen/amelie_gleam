// Teto diário de mensagens por chat (achado M1 do relatório de segurança).

import core/anti_spam.{
  AvisoLimite, Permitido, Silenciado, avaliar, aviso_limite_diario, dia_ms,
  limite_diario_mensagens, limpar_inativos, novo_estado,
}
import gleam/dict
import gleam/option.{None}
import gleeunit/should

/// Intervalo que reabastece mais de um token entre mensagens (1 a cada 12 s).
const intervalo_ms = 13_000

/// Começo de um dia qualquer, longe da meia-noite seguinte.
const inicio = 864_000_000

/// Envia `n` mensagens espaçadas e devolve o estado e o instante final.
fn enviar_n(
  estado: anti_spam.EstadoAntiSpam,
  chat: String,
  n: Int,
  t0: Int,
) -> #(anti_spam.EstadoAntiSpam, Int) {
  case n {
    0 -> #(estado, t0)
    _ -> {
      let #(e2, decisao) = avaliar(estado, chat, chat, "", 1.0, t0)
      decisao |> should.equal(Permitido)
      enviar_n(e2, chat, n - 1, t0 + intervalo_ms)
    }
  }
}

pub fn aceita_ate_o_teto_diario_test() {
  let #(_estado, _t) =
    enviar_n(novo_estado(), "chat_a", limite_diario_mensagens, inicio)
}

pub fn avisa_uma_vez_e_depois_descarta_test() {
  let #(e, t) =
    enviar_n(novo_estado(), "chat_a", limite_diario_mensagens, inicio)

  let #(e2, d1) = avaliar(e, "chat_a", "chat_a", "", 1.0, t)
  d1 |> should.equal(AvisoLimite(aviso_limite_diario))

  let #(_e3, d2) = avaliar(e2, "chat_a", "chat_a", "", 1.0, t + intervalo_ms)
  d2 |> should.equal(Silenciado(None))
}

pub fn teto_zera_no_dia_seguinte_test() {
  let #(e, t) =
    enviar_n(novo_estado(), "chat_a", limite_diario_mensagens, inicio)
  let #(e2, _) = avaliar(e, "chat_a", "chat_a", "", 1.0, t)

  let #(_e3, d) = avaliar(e2, "chat_a", "chat_a", "", 1.0, inicio + dia_ms)
  d |> should.equal(Permitido)
}

pub fn teto_e_por_chat_test() {
  let #(e, t) =
    enviar_n(novo_estado(), "chat_a", limite_diario_mensagens, inicio)
  let #(e2, _) = avaliar(e, "chat_a", "chat_a", "", 1.0, t)

  let #(_e3, d) = avaliar(e2, "chat_b", "chat_b", "", 1.0, t)
  d |> should.equal(Permitido)
}

pub fn pausa_nao_zera_o_teto_test() {
  let #(e, t) =
    enviar_n(novo_estado(), "chat_a", limite_diario_mensagens, inicio)

  // Duas horas paradas: antes, a limpeza de inativos (TTL 1 h) apagava o
  // registro e o contador recomeçava do zero.
  let depois = t + 7_200_000
  let limpo = limpar_inativos(e, depois, 3_600_000)
  dict.has_key(limpo, "chat_a") |> should.be_true

  let #(_e2, d) = avaliar(limpo, "chat_a", "chat_a", "", 1.0, depois)
  d |> should.equal(AvisoLimite(aviso_limite_diario))
}

pub fn admin_nao_tem_teto_test() {
  let admin = "tg:12345"
  let estado = admin_envia(novo_estado(), admin, limite_diario_mensagens + 5, 1)
  dict.size(estado) |> should.equal(0)
}

fn admin_envia(
  estado: anti_spam.EstadoAntiSpam,
  admin: String,
  restantes: Int,
  i: Int,
) -> anti_spam.EstadoAntiSpam {
  case restantes {
    0 -> estado
    _ -> {
      let #(e2, d) =
        avaliar(estado, admin, admin, "12345", 1.0, inicio + i * intervalo_ms)
      d |> should.equal(Permitido)
      admin_envia(e2, admin, restantes - 1, i + 1)
    }
  }
}
