// test/core/anti_spam_test.gleam
// Testes unitários puros para a lógica de rate limiting e anti-spam.

import core/anti_spam.{
  AvisoLimite, Permitido, RegistroChat, Silenciado, avaliar, contar_silenciados,
  desbloquear, extrair_telefone, formatar_identificador,
  formatar_numero_telefone, limpar_inativos, novo_estado, peso_mensagem,
}
import dominio/mensagem.{Audio, Imagem, Texto, Video}
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import helpers/fixtures

pub fn admin_totalmente_isento_test() {
  let estado = novo_estado()
  let agora = 1_000_000

  // Admin enviando 10 mensagens instantâneas seguidas
  let #(estado2, dec1) =
    avaliar(
      estado,
      fixtures.id("tg:12345"),
      fixtures.id("tg:12345"),
      Some(fixtures.id("tg:12345")),
      1.0,
      agora,
    )
  dec1 |> should.equal(Permitido)

  let #(_estado3, dec2) =
    avaliar(
      estado2,
      fixtures.id("tg:12345"),
      fixtures.id("tg:12345"),
      Some(fixtures.id("tg:12345")),
      10.0,
      agora,
    )
  dec2 |> should.equal(Permitido)
}

pub fn burst_natural_4_mensagens_permitido_test() {
  let estado = novo_estado()
  let t0 = 1_000_000

  // 1ª msg
  let #(e1, d1) =
    avaliar(
      estado,
      fixtures.id("user_1@c.us"),
      fixtures.id("user_1@c.us"),
      None,
      1.0,
      t0,
    )
  d1 |> should.equal(Permitido)

  // 2ª msg (1s depois)
  let #(e2, d2) =
    avaliar(
      e1,
      fixtures.id("user_1@c.us"),
      fixtures.id("user_1@c.us"),
      None,
      1.0,
      t0 + 1000,
    )
  d2 |> should.equal(Permitido)

  // 3ª msg (2s depois)
  let #(e3, d3) =
    avaliar(
      e2,
      fixtures.id("user_1@c.us"),
      fixtures.id("user_1@c.us"),
      None,
      1.0,
      t0 + 2000,
    )
  d3 |> should.equal(Permitido)

  // 4ª msg (2.5s depois)
  let #(_e4, d4) =
    avaliar(
      e3,
      fixtures.id("user_1@c.us"),
      fixtures.id("user_1@c.us"),
      None,
      1.0,
      t0 + 2500,
    )
  d4 |> should.equal(Permitido)
}

pub fn strike1_acionado_ao_esgotar_tokens_test() {
  let estado = novo_estado()
  let t0 = 1_000_000

  // Consome os 4 tokens iniciais espaçando para não disparar flood volumétrico (<= 4 msgs em 3s)
  let #(e1, _) =
    avaliar(
      estado,
      fixtures.id("user_1@c.us"),
      fixtures.id("user_1@c.us"),
      None,
      1.0,
      t0,
    )
  let #(e2, _) =
    avaliar(
      e1,
      fixtures.id("user_1@c.us"),
      fixtures.id("user_1@c.us"),
      None,
      1.0,
      t0 + 1200,
    )
  let #(e3, _) =
    avaliar(
      e2,
      fixtures.id("user_1@c.us"),
      fixtures.id("user_1@c.us"),
      None,
      1.0,
      t0 + 2400,
    )
  let #(e4, _) =
    avaliar(
      e3,
      fixtures.id("user_1@c.us"),
      fixtures.id("user_1@c.us"),
      None,
      1.0,
      t0 + 3600,
    )

  // 5ª msg rápida em 4.0s -> balde vazio (< 1 token disponível) -> Strike 1 (cooldown de 30s)
  let #(_e5, d5) =
    avaliar(
      e4,
      fixtures.id("user_1@c.us"),
      fixtures.id("user_1@c.us"),
      None,
      1.0,
      t0 + 4000,
    )
  case d5 {
    AvisoLimite(motivo) -> {
      motivo |> should.not_equal("")
    }
    _ -> panic as "esperava AvisoLimite no Strike 1"
  }
}

pub fn recuperacao_apos_aguardar_cooldown_test() {
  let estado = novo_estado()
  let t0 = 1_000_000

  // Esgota tokens
  let #(e1, _) =
    avaliar(
      estado,
      fixtures.id("user_1@c.us"),
      fixtures.id("user_1@c.us"),
      None,
      4.0,
      t0,
    )
  let #(e2, d2) =
    avaliar(
      e1,
      fixtures.id("user_1@c.us"),
      fixtures.id("user_1@c.us"),
      None,
      1.0,
      t0 + 100,
    )
  case d2 {
    AvisoLimite(_) -> Nil
    _ -> panic as "esperava AvisoLimite"
  }

  // Usuário respeita e aguarda 35 segundos (> 30s de cooldown)
  // Recarga: 35s * 0.0833 = ~2.91 tokens disponíveis
  let #(_e3, d3) =
    avaliar(
      e2,
      fixtures.id("user_1@c.us"),
      fixtures.id("user_1@c.us"),
      None,
      1.0,
      t0 + 35_100,
    )
  d3 |> should.equal(Permitido)
}

pub fn reincidencia_durante_cooldown_escala_para_strike2_test() {
  let estado = novo_estado()
  let t0 = 1_000_000

  // Esgota e entra no Strike 1 (cooldown de 30s)
  let #(e1, _) =
    avaliar(
      estado,
      fixtures.id("user_1@c.us"),
      fixtures.id("user_1@c.us"),
      None,
      4.0,
      t0,
    )
  let #(e2, _) =
    avaliar(
      e1,
      fixtures.id("user_1@c.us"),
      fixtures.id("user_1@c.us"),
      None,
      1.0,
      t0 + 100,
    )

  // Usuário NÃO espera e manda msg 5s depois (ainda dentro dos 30s)
  let #(e3, d3) =
    avaliar(
      e2,
      fixtures.id("user_1@c.us"),
      fixtures.id("user_1@c.us"),
      None,
      1.0,
      t0 + 5000,
    )
  case d3 {
    AvisoLimite(motivo) -> {
      // Aviso de Strike 2 (pausa de 5 minutos)
      motivo |> should.not_equal("")
    }
    _ -> panic as "esperava AvisoLimite de Strike 2"
  }

  // Usuário insiste novamente durante os 5 minutos -> escala para Strike 3 (Quarentena/Jail)
  let #(e4, d4) =
    avaliar(
      e3,
      fixtures.id("user_1@c.us"),
      fixtures.id("user_1@c.us"),
      None,
      1.0,
      t0 + 10_000,
    )
  case d4 {
    Silenciado(notificar_admin) -> {
      notificar_admin |> should.be_some
    }
    _ -> panic as "esperava Silenciado com notificação no Strike 3"
  }

  // Próximas mensagens no Strike 3 devem ser blackhole total (sem alertar admin novamente)
  let #(_e5, d5) =
    avaliar(
      e4,
      fixtures.id("user_1@c.us"),
      fixtures.id("user_1@c.us"),
      None,
      1.0,
      t0 + 15_000,
    )
  case d5 {
    Silenciado(None) -> Nil
    _ -> panic as "esperava Silenciado silencioso (blackhole)"
  }
}

pub fn flood_volumetrico_aciona_strike3_imediatamente_test() {
  let estado = novo_estado()
  let t0 = 1_000_000

  // 5 mensagens em menos de 2 segundos (claramente script/bot)
  let #(e1, _) =
    avaliar(
      estado,
      fixtures.id("bot_spammer@c.us"),
      fixtures.id("bot_spammer@c.us"),
      None,
      0.5,
      t0,
    )
  let #(e2, _) =
    avaliar(
      e1,
      fixtures.id("bot_spammer@c.us"),
      fixtures.id("bot_spammer@c.us"),
      None,
      0.5,
      t0 + 200,
    )
  let #(e3, _) =
    avaliar(
      e2,
      fixtures.id("bot_spammer@c.us"),
      fixtures.id("bot_spammer@c.us"),
      None,
      0.5,
      t0 + 400,
    )
  let #(e4, _) =
    avaliar(
      e3,
      fixtures.id("bot_spammer@c.us"),
      fixtures.id("bot_spammer@c.us"),
      None,
      0.5,
      t0 + 600,
    )

  // 5ª mensagem dentro dos 3 segundos -> detecção volumétrica direta!
  let #(_e5, d5) =
    avaliar(
      e4,
      fixtures.id("bot_spammer@c.us"),
      fixtures.id("bot_spammer@c.us"),
      None,
      0.5,
      t0 + 800,
    )
  case d5 {
    Silenciado(Some(alerta)) -> {
      alerta |> should.not_equal("")
    }
    _ -> panic as "esperava Silenciado imediato por flood volumétrico"
  }
}

pub fn peso_midia_consome_mais_tokens_test() {
  peso_mensagem(Video(caminho_temp: "/tmp/v.mp4", mime: "video/mp4"))
  |> should.equal(3.0)

  peso_mensagem(Audio(dados: <<>>, mime: "audio/ogg"))
  |> should.equal(2.0)

  peso_mensagem(Imagem(dados: <<>>, mime: "image/jpeg"))
  |> should.equal(2.0)

  peso_mensagem(Texto("olá"))
  |> should.equal(1.0)

  // Um vídeo custa 3 tokens de um total de 4
  let estado = novo_estado()
  let t0 = 1_000_000
  let #(e1, d1) =
    avaliar(
      estado,
      fixtures.id("user_v@c.us"),
      fixtures.id("user_v@c.us"),
      None,
      3.0,
      t0,
    )
  d1 |> should.equal(Permitido)

  // O segundo vídeo imediato necessitaria de 3.0 tokens, mas resta apenas 1.0 -> Strike 1
  let #(_e2, d2) =
    avaliar(
      e1,
      fixtures.id("user_v@c.us"),
      fixtures.id("user_v@c.us"),
      None,
      3.0,
      t0 + 500,
    )
  case d2 {
    AvisoLimite(_) -> Nil
    _ -> panic as "esperava AvisoLimite para segundo vídeo imediato"
  }
}

pub fn desbloquear_chat_limpa_estado_test() {
  let estado = novo_estado()
  let t0 = 1_000_000

  // Coloca user em Strike 1
  let #(e1, _) =
    avaliar(
      estado,
      fixtures.id("user_bloqueado@c.us"),
      fixtures.id("user_bloqueado@c.us"),
      None,
      4.0,
      t0,
    )
  let #(e2, _) =
    avaliar(
      e1,
      fixtures.id("user_bloqueado@c.us"),
      fixtures.id("user_bloqueado@c.us"),
      None,
      1.0,
      t0 + 100,
    )

  // Admin executa desbloqueio
  let #(e3, ok) = desbloquear(e2, "user_bloqueado@c.us")
  ok |> should.be_true

  // Agora user_bloqueado está limpo e pode falar de novo
  let #(_e4, d4) =
    avaliar(
      e3,
      fixtures.id("user_bloqueado@c.us"),
      fixtures.id("user_bloqueado@c.us"),
      None,
      1.0,
      t0 + 200,
    )
  d4 |> should.equal(Permitido)
}

pub fn contar_silenciados_e_limpar_inativos_test() {
  let estado = novo_estado()
  let t0 = 1_000_000

  // Insere um chat normal e um chat em quarentena (Strike 3)
  let #(e1, _) =
    avaliar(
      estado,
      fixtures.id("normal@c.us"),
      fixtures.id("normal@c.us"),
      None,
      1.0,
      t0,
    )

  // Spammer aciona strike 3 por flood
  let #(e2, _) =
    avaliar(
      e1,
      fixtures.id("spammer@c.us"),
      fixtures.id("spammer@c.us"),
      None,
      0.5,
      t0,
    )
  let #(e3, _) =
    avaliar(
      e2,
      fixtures.id("spammer@c.us"),
      fixtures.id("spammer@c.us"),
      None,
      0.5,
      t0 + 100,
    )
  let #(e4, _) =
    avaliar(
      e3,
      fixtures.id("spammer@c.us"),
      fixtures.id("spammer@c.us"),
      None,
      0.5,
      t0 + 200,
    )
  let #(e5, _) =
    avaliar(
      e4,
      fixtures.id("spammer@c.us"),
      fixtures.id("spammer@c.us"),
      None,
      0.5,
      t0 + 300,
    )
  let #(e6, _) =
    avaliar(
      e5,
      fixtures.id("spammer@c.us"),
      fixtures.id("spammer@c.us"),
      None,
      0.5,
      t0 + 400,
    )

  contar_silenciados(e6, t0 + 500)
  |> should.equal(1)

  // Limpeza de inativos enquanto a quarentena está ativa (ex: 10s após) preserva o registro
  let e_limpo = limpar_inativos(e6, t0 + 10_000, 3_600_000)
  contar_silenciados(e_limpo, t0 + 10_000)
  |> should.equal(1)
}

pub fn extrair_telefone_test() {
  // Chat privado WhatsApp
  extrair_telefone(fixtures.id("5511999998888@s.whatsapp.net"))
  |> should.equal("+55 (11) 99999-8888")

  // Remetente com dispositivo
  extrair_telefone(fixtures.id("5521988887777:2@s.whatsapp.net"))
  |> should.equal("+55 (21) 98888-7777")

  // Fixo WhatsApp BR
  extrair_telefone(fixtures.id("553133334444@s.whatsapp.net"))
  |> should.equal("+55 (31) 3333-4444")

  // LID
  extrair_telefone(fixtures.id("123456789@lid"))
  |> should.equal("LID: 123456789")

  // Telegram
  extrair_telefone(fixtures.id("tg:987654321"))
  |> should.equal("Telegram: 987654321")
}

pub fn desbloquear_aceita_telefone_ou_id_completo_test() {
  let t0 = 1_000_000
  let wa = fixtures.id("5531999990000@s.whatsapp.net")
  let tg = fixtures.id("tg:987654321")
  let #(e1, _) = avaliar(novo_estado(), wa, wa, None, 4.0, t0)
  let #(e2, _) = avaliar(e1, tg, tg, None, 4.0, t0)

  // Como o exemplo da ajuda: só o número, com ou sem pontuação
  let #(e3, ok) = desbloquear(e2, "+55 (31) 99999-0000")
  ok |> should.be_true
  let #(e4, ok) = desbloquear(e3, "5531999990000")
  ok |> should.be_false

  let #(_, ok) = desbloquear(e4, "tg:987654321")
  ok |> should.be_true

  desbloquear(e2, "123") |> should.equal(#(e2, False))
}

pub fn formatar_identificador_e_numero_test() {
  // Celular BR (13 dígitos)
  formatar_identificador(fixtures.id("5511999998888@s.whatsapp.net"))
  |> should.equal("+55 (11) 99999-8888")

  // Fixo BR (12 dígitos)
  formatar_identificador(fixtures.id("553133334444@c.us"))
  |> should.equal("+55 (31) 3333-4444")

  // LID
  formatar_identificador(fixtures.id("123456789@lid"))
  |> should.equal("LID: 123456789")

  // Telegram
  formatar_identificador(fixtures.id("tg:987654321"))
  |> should.equal("Telegram: 987654321")

  // Formatar número puro
  formatar_numero_telefone("5511999998888")
  |> should.equal("+55 (11) 99999-8888")

  formatar_numero_telefone("553133334444")
  |> should.equal("+55 (31) 3333-4444")

  formatar_numero_telefone("14155552671")
  |> should.equal("+14155552671")
}

// ---------------------------------------------------------------------------
// Mensagens atrasadas (enviadas com a Amélie fora do ar)
// ---------------------------------------------------------------------------

pub fn atrasadas_em_lote_nao_sao_rajada_test() {
  let chat = fixtures.id("user_1@c.us")
  let agora = 1_000_000

  // Dez mensagens no mesmo instante: no ritmo normal seria flood (strike 3).
  let #(estado, decisoes) =
    list.fold(list.repeat(Nil, 10), #(novo_estado(), []), fn(acc, _) {
      let #(estado, decisoes) = acc
      let #(estado, decisao) =
        anti_spam.avaliar_atrasada(estado, chat, chat, None, agora)
      #(estado, [decisao, ..decisoes])
    })
  decisoes |> list.all(fn(d) { d == Permitido }) |> should.be_true

  // Nem strike, nem token gasto: a próxima mensagem no horário passa.
  let #(_, decisao) = avaliar(estado, chat, chat, None, 1.0, agora + 1000)
  decisao |> should.equal(Permitido)
}

pub fn atrasada_de_chat_em_quarentena_segue_silenciada_test() {
  let chat = fixtures.id("user_1@c.us")
  let t0 = 1_000_000

  // Flood no horário: strike 3, quarentena de 30 min.
  let estado =
    list.fold([0, 1, 2, 3, 4], novo_estado(), fn(estado, i) {
      avaliar(estado, chat, chat, None, 1.0, t0 + i * 100).0
    })

  anti_spam.avaliar_atrasada(estado, chat, chat, None, t0 + 1000).1
  |> should.equal(Silenciado(None))
}

pub fn atrasadas_respeitam_teto_diario_test() {
  let chat = fixtures.id("user_1@c.us")
  let agora = 1_000_000

  let estado =
    list.fold(
      list.repeat(Nil, anti_spam.limite_diario_mensagens),
      novo_estado(),
      fn(estado, _) {
        anti_spam.avaliar_atrasada(estado, chat, chat, None, agora).0
      },
    )

  let #(estado, decisao) =
    anti_spam.avaliar_atrasada(estado, chat, chat, None, agora)
  decisao |> should.equal(AvisoLimite(anti_spam.aviso_limite_diario))
  anti_spam.avaliar_atrasada(estado, chat, chat, None, agora).1
  |> should.equal(Silenciado(None))
}

pub fn atrasada_do_admin_e_permitida_test() {
  let admin = fixtures.id("tg:12345")
  anti_spam.avaliar_atrasada(novo_estado(), admin, admin, Some(admin), 0).1
  |> should.equal(Permitido)
}

pub fn album_de_fotos_nao_escala_strike_test() {
  let id = fixtures.id("album@c.us")
  let t0 = 1_000_000
  let foto = fn(estado, t) { avaliar(estado, id, id, None, 2.0, t) }

  let #(e1, d1) = foto(novo_estado(), t0)
  let #(e2, d2) = foto(e1, t0 + 100)
  let #(e3, d3) = foto(e2, t0 + 200)
  let #(e4, d4) = foto(e3, t0 + 300)
  let #(e5, d5) = foto(e4, t0 + 400)
  let #(_e6, d6) = foto(e5, t0 + 500)

  d1 |> should.equal(Permitido)
  d2 |> should.equal(Permitido)
  // A 3ª foto esgota o balde: um único aviso de 30 s.
  case d3 {
    AvisoLimite(_) -> Nil
    _ -> panic as "esperava AvisoLimite na 3ª foto"
  }
  // As demais já estavam a caminho: descartadas sem escalar nem alertar o admin.
  d4 |> should.equal(Silenciado(None))
  d5 |> should.equal(Silenciado(None))
  d6 |> should.equal(Silenciado(None))
  let assert Ok(reg) = dict.get(e5, id)
  reg.strikes |> should.equal(1)
}

pub fn reincidente_no_strike2_vai_para_quarentena_de_30_min_test() {
  let id = fixtures.id("reincidente@c.us")
  let t0 = 10_000_000
  // Já cumpriu a pausa de 5 min do strike 2 e voltou sem esperar o perdão.
  let estado =
    dict.from_list([
      #(
        id,
        RegistroChat(
          tokens: 0.0,
          ultimo_ts_ms: t0 - 1000,
          strikes: 2,
          quarentena_ate_ms: t0 - 1000,
          recentes_ts: [],
          dia: t0 / anti_spam.dia_ms,
          mensagens_no_dia: 10,
        ),
      ),
    ])

  let #(e1, d1) = avaliar(estado, id, id, None, 1.0, t0)

  case d1 {
    Silenciado(Some(_)) -> Nil
    _ -> panic as "esperava quarentena com alerta ao admin"
  }
  let assert Ok(reg) = dict.get(e1, id)
  reg.strikes |> should.equal(3)
  reg.quarentena_ate_ms |> should.equal(t0 + anti_spam.quarentena_strike3_ms)
}

pub fn flood_de_texto_continua_detectado_e_midia_nao_conta_test() {
  let id = fixtures.id("misto@c.us")
  let t0 = 1_000_000
  // 4 textos rápidos não são flood; uma imagem no meio não completa os 5.
  let #(e1, _) = avaliar(novo_estado(), id, id, None, 0.5, t0)
  let #(e2, _) = avaliar(e1, id, id, None, 0.5, t0 + 100)
  let #(e3, _) = avaliar(e2, id, id, None, 0.5, t0 + 200)
  let #(e4, _) = avaliar(e3, id, id, None, 2.0, t0 + 300)
  let #(_, d5) = avaliar(e4, id, id, None, 0.5, t0 + 400)
  case d5 {
    Silenciado(Some(_)) -> panic as "imagem não deveria contar para o flood"
    _ -> Nil
  }
}
