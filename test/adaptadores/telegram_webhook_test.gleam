import adaptadores/telegram_webhook
import dominio/config
import dominio/mensagem.{Comando, Texto}
import gleam/bit_array
import gleam/erlang/process
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import helpers/fixtures
import helpers/portas_fake
import shell/fila_midia
import shell/handler_mensagem.{Portas}
import shell/metricas

pub fn parsear_mensagem_privada_texto_test() {
  let json =
    "{\"update_id\":1001,\"message\":{\"message_id\":42,\"date\":1700000000,\"chat\":{\"id\":998877,\"type\":\"private\"},\"from\":{\"id\":998877},\"text\":\"Olá Amélie!\"}}"
    |> bit_array.from_string

  let assert Ok(Some(msg)) = telegram_webhook.parsear_update(json)
  msg.chat_id |> should.equal("tg:998877")
  msg.remetente |> should.equal("tg:998877")
  msg.message_id |> should.equal(Some("42"))
  msg.em_grupo |> should.be_false
  msg.menciona_bot |> should.be_true
  msg.corpo |> should.equal(Texto("Olá Amélie!"))
}

pub fn parsear_comando_barra_test() {
  let json =
    "{\"update_id\":1002,\"message\":{\"message_id\":43,\"date\":1700000000,\"chat\":{\"id\":998877,\"type\":\"private\"},\"text\":\"/ajuda\"}}"
    |> bit_array.from_string

  let assert Ok(Some(msg)) = telegram_webhook.parsear_update(json)
  msg.corpo |> should.equal(Comando("ajuda", ""))
}

pub fn parsear_comando_start_com_botname_test() {
  let json =
    "{\"update_id\":1003,\"message\":{\"message_id\":44,\"date\":1700000000,\"chat\":{\"id\":998877,\"type\":\"private\"},\"text\":\"/start@AmelieBot\"}}"
    |> bit_array.from_string

  let assert Ok(Some(msg)) = telegram_webhook.parsear_update(json)
  msg.corpo |> should.equal(Comando("start", ""))
}

pub fn parsear_comando_cego_com_ponto_test() {
  let json =
    "{\"update_id\":1004,\"message\":{\"message_id\":45,\"date\":1700000000,\"chat\":{\"id\":998877,\"type\":\"private\"},\"text\":\".cego\"}}"
    |> bit_array.from_string

  let assert Ok(Some(msg)) = telegram_webhook.parsear_update(json)
  msg.corpo |> should.equal(Comando("cego", ""))
}

pub fn rejeitar_mensagem_de_grupo_test() {
  let json_grupo =
    "{\"update_id\":1005,\"message\":{\"message_id\":46,\"date\":1700000000,\"chat\":{\"id\":-10012345,\"type\":\"group\"},\"text\":\"oi no grupo\"}}"
    |> bit_array.from_string

  // Grupos devem ser categoricamente ignorados (None)
  let assert Ok(None) = telegram_webhook.parsear_update(json_grupo)

  let json_supergrupo =
    "{\"update_id\":1006,\"message\":{\"message_id\":47,\"date\":1700000000,\"chat\":{\"id\":-10098765,\"type\":\"supergroup\"},\"text\":\"/ajuda\"}}"
    |> bit_array.from_string

  let assert Ok(None) = telegram_webhook.parsear_update(json_supergrupo)
}

pub fn update_sem_message_retorna_none_test() {
  let json =
    "{\"update_id\":1007}"
    |> bit_array.from_string

  let assert Ok(None) = telegram_webhook.parsear_update(json)
}

pub fn update_sem_texto_retorna_none_test() {
  let json =
    "{\"update_id\":1008,\"message\":{\"message_id\":48,\"date\":1700000000,\"chat\":{\"id\":998877,\"type\":\"private\"}}}"
    |> bit_array.from_string

  let assert Ok(None) = telegram_webhook.parsear_update(json)
}

pub fn fluxo_telegram_com_handler_mensagem_test() {
  let ref_envio = process.new_subject()
  let assert Ok(filas) = fila_midia.iniciar_todas()
  let assert Ok(met) = metricas.iniciar()

  let portas =
    Portas(
      mensageiro: portas_fake.mensageiro_capturar(ref_envio),
      ia_dispatcher: portas_fake.ia_dispatcher_ok(
        "Olá humano! Sou a Amélie no Telegram.",
      ),
      config: portas_fake.config_ok(
        config.Config(..fixtures.config_padrao(), chat_id: "tg:555444"),
      ),
      historico: portas_fake.historico_vazio(),
      fila: filas,
      prompts: portas_fake.prompt_noop(),
      metricas: met,
      usuarios: portas_fake.usuario_noop(),
      grupos: portas_fake.grupo_noop(),
      transacoes: portas_fake.transacao_noop(),
      providers_config: portas_fake.providers_config_ok(),
    )

  let json =
    "{\"update_id\":2001,\"message\":{\"message_id\":50,\"date\":0,\"chat\":{\"id\":555444,\"type\":\"private\"},\"text\":\"/start\"}}"
    |> bit_array.from_string

  let assert Ok(Some(msg)) = telegram_webhook.parsear_update(json)
  let _ = handler_mensagem.handle(msg, portas)

  // Deve responder com a mensagem de ajuda para o chat tg:555444
  let assert Ok(#(chat_id, texto)) = process.receive(ref_envio, 1000)
  chat_id |> should.equal("tg:555444")
  // Verifica se é a mensagem de comandos
  should.be_true(string.contains(texto, "Amélie — Comandos disponíveis"))
}

pub fn fluxo_telegram_conversa_ia_test() {
  let ref_envio = process.new_subject()
  let assert Ok(filas) = fila_midia.iniciar_todas()
  let assert Ok(met) = metricas.iniciar()

  let portas =
    Portas(
      mensageiro: portas_fake.mensageiro_capturar(ref_envio),
      ia_dispatcher: portas_fake.ia_dispatcher_ok(
        "Olá! Sou a Amélie no Telegram. Como posso te ajudar hoje?",
      ),
      config: portas_fake.config_ok(
        config.Config(..fixtures.config_padrao(), chat_id: "tg:555444"),
      ),
      historico: portas_fake.historico_vazio(),
      fila: filas,
      prompts: portas_fake.prompt_noop(),
      metricas: met,
      usuarios: portas_fake.usuario_noop(),
      grupos: portas_fake.grupo_noop(),
      transacoes: portas_fake.transacao_noop(),
      providers_config: portas_fake.providers_config_ok(),
    )

  let json =
    "{\"update_id\":2002,\"message\":{\"message_id\":51,\"date\":0,\"chat\":{\"id\":555444,\"type\":\"private\"},\"text\":\"Olá Amélie!\"}}"
    |> bit_array.from_string

  let assert Ok(Some(msg)) = telegram_webhook.parsear_update(json)
  let _ = handler_mensagem.handle(msg, portas)

  // Deve responder com o texto gerado pela IA para o chat tg:555444
  let assert Ok(#(chat_id, texto)) = process.receive(ref_envio, 1000)
  chat_id |> should.equal("tg:555444")
  texto
  |> should.equal("Olá! Sou a Amélie no Telegram. Como posso te ajudar hoje?")
}

pub fn parsear_evento_foto_alta_resolucao_test() {
  let json =
    "{\"update_id\":3001,\"message\":{\"message_id\":70,\"date\":1700000000,\"chat\":{\"id\":998877,\"type\":\"private\"},\"from\":{\"id\":998877},\"photo\":[{\"file_id\":\"thumb_id\",\"width\":90,\"height\":90},{\"file_id\":\"hd_file_id\",\"width\":1280,\"height\":720}]}}"
    |> bit_array.from_string

  let assert Ok(evento) = telegram_webhook.parsear_evento(json)
  case evento {
    telegram_webhook.EventoFotoParaBaixar(update_id, base, file_id) -> {
      update_id |> should.equal(3001)
      file_id |> should.equal("hd_file_id")
      base.chat_id |> should.equal("tg:998877")
      base.remetente |> should.equal("tg:998877")
      base.message_id |> should.equal(Some("70"))
      base.legenda |> should.be_none
    }
    _ -> should.fail()
  }
}

pub fn parsear_evento_foto_com_legenda_test() {
  let json =
    "{\"update_id\":3002,\"message\":{\"message_id\":71,\"date\":1700000000,\"chat\":{\"id\":998877,\"type\":\"private\"},\"caption\":\"Descreva esta imagem por favor\",\"photo\":[{\"file_id\":\"pic_123\",\"width\":640,\"height\":480}]}}"
    |> bit_array.from_string

  let assert Ok(evento) = telegram_webhook.parsear_evento(json)
  case evento {
    telegram_webhook.EventoFotoParaBaixar(update_id, base, file_id) -> {
      update_id |> should.equal(3002)
      file_id |> should.equal("pic_123")
      base.legenda |> should.equal(Some("Descreva esta imagem por favor"))
    }
    _ -> should.fail()
  }
}

pub fn parsear_evento_voice_audio_ogg_test() {
  let json =
    "{\"update_id\":3003,\"message\":{\"message_id\":72,\"date\":1700000000,\"chat\":{\"id\":998877,\"type\":\"private\"},\"voice\":{\"file_id\":\"voice_abc\",\"mime_type\":\"audio/ogg\",\"duration\":8}}}"
    |> bit_array.from_string

  let assert Ok(evento) = telegram_webhook.parsear_evento(json)
  case evento {
    telegram_webhook.EventoAudioParaBaixar(update_id, base, file_id, mime) -> {
      update_id |> should.equal(3003)
      file_id |> should.equal("voice_abc")
      mime |> should.equal("audio/ogg")
      base.chat_id |> should.equal("tg:998877")
    }
    _ -> should.fail()
  }
}

pub fn parsear_evento_audio_mp3_test() {
  let json =
    "{\"update_id\":3004,\"message\":{\"message_id\":73,\"date\":1700000000,\"chat\":{\"id\":998877,\"type\":\"private\"},\"caption\":\"Música do recital\",\"audio\":{\"file_id\":\"audio_xyz\",\"mime_type\":\"audio/mp3\",\"duration\":120}}}"
    |> bit_array.from_string

  let assert Ok(evento) = telegram_webhook.parsear_evento(json)
  case evento {
    telegram_webhook.EventoAudioParaBaixar(update_id, base, file_id, mime) -> {
      update_id |> should.equal(3004)
      file_id |> should.equal("audio_xyz")
      mime |> should.equal("audio/mp3")
      base.legenda |> should.equal(Some("Música do recital"))
    }
    _ -> should.fail()
  }
}

pub fn parsear_evento_midia_em_grupo_rejeitada_test() {
  let json_foto_grupo =
    "{\"update_id\":3005,\"message\":{\"message_id\":74,\"date\":1700000000,\"chat\":{\"id\":-1008899,\"type\":\"group\"},\"photo\":[{\"file_id\":\"pic_grupo\",\"width\":100,\"height\":100}]}}"
    |> bit_array.from_string

  let assert Ok(evento) = telegram_webhook.parsear_evento(json_foto_grupo)
  case evento {
    telegram_webhook.EventoIgnorado(id) -> id |> should.equal(3005)
    _ -> should.fail()
  }

  let json_voz_supergrupo =
    "{\"update_id\":3006,\"message\":{\"message_id\":75,\"date\":1700000000,\"chat\":{\"id\":-1008899,\"type\":\"supergroup\"},\"voice\":{\"file_id\":\"voice_grupo\",\"mime_type\":\"audio/ogg\"}}}"
    |> bit_array.from_string

  let assert Ok(evento2) = telegram_webhook.parsear_evento(json_voz_supergrupo)
  case evento2 {
    telegram_webhook.EventoIgnorado(id) -> id |> should.equal(3006)
    _ -> should.fail()
  }
}

pub fn parsear_evento_video_test() {
  let json =
    "{\"update_id\":4001,\"message\":{\"message_id\":80,\"date\":1700000000,\"chat\":{\"id\":998877,\"type\":\"private\"},\"video\":{\"file_id\":\"vid_abc123\",\"mime_type\":\"video/mp4\",\"duration\":15}}}"
    |> bit_array.from_string

  let assert Ok(evento) = telegram_webhook.parsear_evento(json)
  case evento {
    telegram_webhook.EventoVideoParaBaixar(update_id, base, file_id, mime) -> {
      update_id |> should.equal(4001)
      file_id |> should.equal("vid_abc123")
      mime |> should.equal("video/mp4")
      base.chat_id |> should.equal("tg:998877")
      base.legenda |> should.be_none
    }
    _ -> should.fail()
  }
}

pub fn parsear_evento_video_com_legenda_test() {
  let json =
    "{\"update_id\":4002,\"message\":{\"message_id\":81,\"date\":1700000000,\"chat\":{\"id\":998877,\"type\":\"private\"},\"caption\":\"Explique o que acontece no vídeo\",\"video\":{\"file_id\":\"vid_xyz789\",\"mime_type\":\"video/quicktime\",\"duration\":20}}}"
    |> bit_array.from_string

  let assert Ok(evento) = telegram_webhook.parsear_evento(json)
  case evento {
    telegram_webhook.EventoVideoParaBaixar(update_id, base, file_id, mime) -> {
      update_id |> should.equal(4002)
      file_id |> should.equal("vid_xyz789")
      mime |> should.equal("video/quicktime")
      base.legenda |> should.equal(Some("Explique o que acontece no vídeo"))
    }
    _ -> should.fail()
  }
}

pub fn parsear_evento_video_note_test() {
  let json =
    "{\"update_id\":4003,\"message\":{\"message_id\":82,\"date\":1700000000,\"chat\":{\"id\":998877,\"type\":\"private\"},\"video_note\":{\"file_id\":\"note_round1\",\"duration\":6}}}"
    |> bit_array.from_string

  let assert Ok(evento) = telegram_webhook.parsear_evento(json)
  case evento {
    telegram_webhook.EventoVideoParaBaixar(update_id, base, file_id, mime) -> {
      update_id |> should.equal(4003)
      file_id |> should.equal("note_round1")
      mime |> should.equal("video/mp4")
      base.chat_id |> should.equal("tg:998877")
    }
    _ -> should.fail()
  }
}

pub fn parsear_evento_video_em_grupo_rejeitado_test() {
  let json =
    "{\"update_id\":4004,\"message\":{\"message_id\":83,\"date\":1700000000,\"chat\":{\"id\":-1002345,\"type\":\"group\"},\"video\":{\"file_id\":\"vid_group\",\"mime_type\":\"video/mp4\"}}}"
    |> bit_array.from_string

  let assert Ok(evento) = telegram_webhook.parsear_evento(json)
  case evento {
    telegram_webhook.EventoIgnorado(id) -> id |> should.equal(4004)
    _ -> should.fail()
  }
}

pub fn parsear_evento_animation_test() {
  let json =
    "{\"update_id\":4005,\"message\":{\"message_id\":84,\"date\":1700000000,\"chat\":{\"id\":998877,\"type\":\"private\"},\"animation\":{\"file_id\":\"anim_gif123\",\"duration\":3}}}"
    |> bit_array.from_string

  let assert Ok(evento) = telegram_webhook.parsear_evento(json)
  case evento {
    telegram_webhook.EventoVideoParaBaixar(update_id, base, file_id, mime) -> {
      update_id |> should.equal(4005)
      file_id |> should.equal("anim_gif123")
      mime |> should.equal("video/mp4")
      base.chat_id |> should.equal("tg:998877")
      base.legenda |> should.equal(Some("Animação/GIF sem áudio"))
    }
    _ -> should.fail()
  }
}

pub fn parsear_evento_document_como_video_test() {
  let json =
    "{\"update_id\":4006,\"message\":{\"message_id\":85,\"date\":1700000000,\"chat\":{\"id\":998877,\"type\":\"private\"},\"document\":{\"file_id\":\"doc_vid_123\",\"file_name\":\"filme.mkv\",\"mime_type\":\"video/x-matroska\"}}}"
    |> bit_array.from_string

  let assert Ok(evento) = telegram_webhook.parsear_evento(json)
  case evento {
    telegram_webhook.EventoVideoParaBaixar(update_id, base, file_id, mime) -> {
      update_id |> should.equal(4006)
      file_id |> should.equal("doc_vid_123")
      mime |> should.equal("video/x-matroska")
      base.chat_id |> should.equal("tg:998877")
    }
    _ -> should.fail()
  }
}

pub fn parsear_evento_documento_generico_test() {
  let json =
    "{\"update_id\":5001,\"message\":{\"message_id\":90,\"date\":1700000000,\"chat\":{\"id\":998877,\"type\":\"private\"},\"document\":{\"file_id\":\"doc_pdf_123\",\"file_name\":\"relatorio.pdf\",\"mime_type\":\"application/pdf\"}}}"
    |> bit_array.from_string

  let assert Ok(evento) = telegram_webhook.parsear_evento(json)
  case evento {
    telegram_webhook.EventoDocumentoParaBaixar(
      update_id,
      base,
      file_id,
      mime,
      file_name,
    ) -> {
      update_id |> should.equal(5001)
      file_id |> should.equal("doc_pdf_123")
      mime |> should.equal("application/pdf")
      file_name |> should.equal("relatorio.pdf")
      base.chat_id |> should.equal("tg:998877")
    }
    _ -> should.fail()
  }
}

pub fn parsear_evento_sticker_estatico_test() {
  let json =
    "{\"update_id\":5002,\"message\":{\"message_id\":91,\"date\":1700000000,\"chat\":{\"id\":998877,\"type\":\"private\"},\"sticker\":{\"file_id\":\"stk_webp_123\",\"emoji\":\"🎉\",\"is_video\":false}}}"
    |> bit_array.from_string

  let assert Ok(evento) = telegram_webhook.parsear_evento(json)
  case evento {
    telegram_webhook.EventoStickerParaBaixar(update_id, base, file_id, mime) -> {
      update_id |> should.equal(5002)
      file_id |> should.equal("stk_webp_123")
      mime |> should.equal("image/webp")
      base.chat_id |> should.equal("tg:998877")
      base.legenda |> should.equal(Some("🎉"))
    }
    _ -> should.fail()
  }
}

pub fn parsear_evento_sticker_video_test() {
  let json =
    "{\"update_id\":5003,\"message\":{\"message_id\":92,\"date\":1700000000,\"chat\":{\"id\":998877,\"type\":\"private\"},\"sticker\":{\"file_id\":\"stk_webm_456\",\"is_video\":true}}}"
    |> bit_array.from_string

  let assert Ok(evento) = telegram_webhook.parsear_evento(json)
  case evento {
    telegram_webhook.EventoStickerParaBaixar(update_id, base, file_id, mime) -> {
      update_id |> should.equal(5003)
      file_id |> should.equal("stk_webm_456")
      mime |> should.equal("video/webm")
      base.chat_id |> should.equal("tg:998877")
      base.legenda |> should.be_none
    }
    _ -> should.fail()
  }
}

pub fn parsear_evento_documento_em_grupo_rejeitado_test() {
  let json =
    "{\"update_id\":5004,\"message\":{\"message_id\":93,\"date\":1700000000,\"chat\":{\"id\":-1002345,\"type\":\"group\"},\"document\":{\"file_id\":\"doc_grupo\",\"file_name\":\"ata.pdf\",\"mime_type\":\"application/pdf\"}}}"
    |> bit_array.from_string

  let assert Ok(evento) = telegram_webhook.parsear_evento(json)
  case evento {
    telegram_webhook.EventoIgnorado(id) -> id |> should.equal(5004)
    _ -> should.fail()
  }
}

pub fn parsear_evento_sticker_em_grupo_rejeitado_test() {
  let json =
    "{\"update_id\":5005,\"message\":{\"message_id\":94,\"date\":1700000000,\"chat\":{\"id\":-1002345,\"type\":\"supergroup\"},\"sticker\":{\"file_id\":\"stk_grupo\",\"is_video\":false}}}"
    |> bit_array.from_string

  let assert Ok(evento) = telegram_webhook.parsear_evento(json)
  case evento {
    telegram_webhook.EventoIgnorado(id) -> id |> should.equal(5005)
    _ -> should.fail()
  }
}
