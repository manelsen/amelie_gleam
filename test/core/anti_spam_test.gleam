// test/core/anti_spam_test.gleam
// Testes unitários puros para a lógica de rate limiting e anti-spam.

import core/anti_spam.{
  AvisoLimite, Permitido, Silenciado, avaliar, contar_silenciados, desbloquear,
  limpar_inativos, novo_estado, peso_mensagem,
}
import dominio/mensagem.{Audio, Imagem, Texto, Video}
import gleam/option.{None, Some}
import gleeunit/should

pub fn admin_totalmente_isento_test() {
  let estado = novo_estado()
  let agora = 1_000_000

  // Admin enviando 10 mensagens instantâneas seguidas
  let #(estado2, dec1) =
    avaliar(estado, "tg:12345", "tg:12345", "12345", 1.0, agora)
  dec1 |> should.equal(Permitido)

  let #(_estado3, dec2) =
    avaliar(estado2, "tg:12345", "tg:12345", "12345", 10.0, agora)
  dec2 |> should.equal(Permitido)
}

pub fn burst_natural_4_mensagens_permitido_test() {
  let estado = novo_estado()
  let t0 = 1_000_000

  // 1ª msg
  let #(e1, d1) = avaliar(estado, "user_1", "user_1", "", 1.0, t0)
  d1 |> should.equal(Permitido)

  // 2ª msg (1s depois)
  let #(e2, d2) = avaliar(e1, "user_1", "user_1", "", 1.0, t0 + 1000)
  d2 |> should.equal(Permitido)

  // 3ª msg (2s depois)
  let #(e3, d3) = avaliar(e2, "user_1", "user_1", "", 1.0, t0 + 2000)
  d3 |> should.equal(Permitido)

  // 4ª msg (2.5s depois)
  let #(_e4, d4) = avaliar(e3, "user_1", "user_1", "", 1.0, t0 + 2500)
  d4 |> should.equal(Permitido)
}

pub fn strike1_acionado_ao_esgotar_tokens_test() {
  let estado = novo_estado()
  let t0 = 1_000_000

  // Consome os 4 tokens iniciais espaçando para não disparar flood volumétrico (<= 4 msgs em 3s)
  let #(e1, _) = avaliar(estado, "user_1", "user_1", "", 1.0, t0)
  let #(e2, _) = avaliar(e1, "user_1", "user_1", "", 1.0, t0 + 1200)
  let #(e3, _) = avaliar(e2, "user_1", "user_1", "", 1.0, t0 + 2400)
  let #(e4, _) = avaliar(e3, "user_1", "user_1", "", 1.0, t0 + 3600)

  // 5ª msg rápida em 4.0s -> balde vazio (< 1 token disponível) -> Strike 1 (cooldown de 30s)
  let #(_e5, d5) = avaliar(e4, "user_1", "user_1", "", 1.0, t0 + 4000)
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
  let #(e1, _) = avaliar(estado, "user_1", "user_1", "", 4.0, t0)
  let #(e2, d2) = avaliar(e1, "user_1", "user_1", "", 1.0, t0 + 100)
  case d2 {
    AvisoLimite(_) -> Nil
    _ -> panic as "esperava AvisoLimite"
  }

  // Usuário respeita e aguarda 35 segundos (> 30s de cooldown)
  // Recarga: 35s * 0.0833 = ~2.91 tokens disponíveis
  let #(_e3, d3) = avaliar(e2, "user_1", "user_1", "", 1.0, t0 + 35_100)
  d3 |> should.equal(Permitido)
}

pub fn reincidencia_durante_cooldown_escala_para_strike2_test() {
  let estado = novo_estado()
  let t0 = 1_000_000

  // Esgota e entra no Strike 1 (cooldown de 30s)
  let #(e1, _) = avaliar(estado, "user_1", "user_1", "", 4.0, t0)
  let #(e2, _) = avaliar(e1, "user_1", "user_1", "", 1.0, t0 + 100)

  // Usuário NÃO espera e manda msg 5s depois (ainda dentro dos 30s)
  let #(e3, d3) = avaliar(e2, "user_1", "user_1", "", 1.0, t0 + 5000)
  case d3 {
    AvisoLimite(motivo) -> {
      // Aviso de Strike 2 (pausa de 5 minutos)
      motivo |> should.not_equal("")
    }
    _ -> panic as "esperava AvisoLimite de Strike 2"
  }

  // Usuário insiste novamente durante os 5 minutos -> escala para Strike 3 (Quarentena/Jail)
  let #(e4, d4) = avaliar(e3, "user_1", "user_1", "", 1.0, t0 + 10_000)
  case d4 {
    Silenciado(notificar_admin) -> {
      notificar_admin |> should.be_some
    }
    _ -> panic as "esperava Silenciado com notificação no Strike 3"
  }

  // Próximas mensagens no Strike 3 devem ser blackhole total (sem alertar admin novamente)
  let #(_e5, d5) = avaliar(e4, "user_1", "user_1", "", 1.0, t0 + 15_000)
  case d5 {
    Silenciado(None) -> Nil
    _ -> panic as "esperava Silenciado silencioso (blackhole)"
  }
}

pub fn flood_volumetrico_aciona_strike3_imediatamente_test() {
  let estado = novo_estado()
  let t0 = 1_000_000

  // 5 mensagens em menos de 2 segundos (claramente script/bot)
  let #(e1, _) = avaliar(estado, "bot_spammer", "bot_spammer", "", 0.5, t0)
  let #(e2, _) = avaliar(e1, "bot_spammer", "bot_spammer", "", 0.5, t0 + 200)
  let #(e3, _) = avaliar(e2, "bot_spammer", "bot_spammer", "", 0.5, t0 + 400)
  let #(e4, _) = avaliar(e3, "bot_spammer", "bot_spammer", "", 0.5, t0 + 600)

  // 5ª mensagem dentro dos 3 segundos -> detecção volumétrica direta!
  let #(_e5, d5) = avaliar(e4, "bot_spammer", "bot_spammer", "", 0.5, t0 + 800)
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
  let #(e1, d1) = avaliar(estado, "user_v", "user_v", "", 3.0, t0)
  d1 |> should.equal(Permitido)

  // O segundo vídeo imediato necessitaria de 3.0 tokens, mas resta apenas 1.0 -> Strike 1
  let #(_e2, d2) = avaliar(e1, "user_v", "user_v", "", 3.0, t0 + 500)
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
    avaliar(estado, "user_bloqueado", "user_bloqueado", "", 4.0, t0)
  let #(e2, _) =
    avaliar(e1, "user_bloqueado", "user_bloqueado", "", 1.0, t0 + 100)

  // Admin executa desbloqueio
  let #(e3, ok) = desbloquear(e2, "user_bloqueado")
  ok |> should.be_true

  // Agora user_bloqueado está limpo e pode falar de novo
  let #(_e4, d4) =
    avaliar(e3, "user_bloqueado", "user_bloqueado", "", 1.0, t0 + 200)
  d4 |> should.equal(Permitido)
}

pub fn contar_silenciados_e_limpar_inativos_test() {
  let estado = novo_estado()
  let t0 = 1_000_000

  // Insere um chat normal e um chat em quarentena (Strike 3)
  let #(e1, _) = avaliar(estado, "normal", "normal", "", 1.0, t0)

  // Spammer aciona strike 3 por flood
  let #(e2, _) = avaliar(e1, "spammer", "spammer", "", 0.5, t0)
  let #(e3, _) = avaliar(e2, "spammer", "spammer", "", 0.5, t0 + 100)
  let #(e4, _) = avaliar(e3, "spammer", "spammer", "", 0.5, t0 + 200)
  let #(e5, _) = avaliar(e4, "spammer", "spammer", "", 0.5, t0 + 300)
  let #(e6, _) = avaliar(e5, "spammer", "spammer", "", 0.5, t0 + 400)

  contar_silenciados(e6, t0 + 500)
  |> should.equal(1)

  // Limpeza de inativos enquanto a quarentena está ativa (ex: 10s após) preserva o registro
  let e_limpo = limpar_inativos(e6, t0 + 10_000, 3_600_000)
  contar_silenciados(e_limpo, t0 + 10_000)
  |> should.equal(1)
}
