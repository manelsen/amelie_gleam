import adaptadores/telegram_webhook
import dominio/config
import dominio/erro
import dominio/mensagem
import gleam/erlang/process
import gleam/string
import gleeunit/should
import helpers/fixtures
import helpers/portas_fake
import portas/telegram_porta
import shell/fila_atrasadas
import shell/fila_midia
import shell/metricas
import shell/receptor_telegram
import shell/sistema
import shell/tratador_mensagem.{type Portas, Portas}

pub fn extrair_updates_json_test() {
  let json =
    "{\"ok\":true,\"result\":[{\"update_id\":5001,\"message\":{\"message_id\":10,\"date\":0,\"chat\":{\"id\":887766,\"type\":\"private\"},\"text\":\"/start\"}},{\"update_id\":5002,\"message\":{\"message_id\":11,\"date\":0,\"chat\":{\"id\":-10099,\"type\":\"group\"},\"text\":\"no grupo\"}}]}"

  let assert Ok(updates) = telegram_webhook.extrair_updates(json)
  let assert [u1, u2] = updates

  case u1 {
    telegram_porta.EventoMensagemPronta(id, msg) -> {
      id |> should.equal(5001)
      msg.chat_id |> should.equal(fixtures.id("tg:887766"))
    }
    _ -> should.fail()
  }

  // Grupo deve ser ignorado (EventoIgnorado)
  case u2 {
    telegram_porta.EventoIgnorado(id) -> id |> should.equal(5002)
    _ -> should.fail()
  }
}

pub fn processar_updates_avanca_offset_e_despacha_test() {
  let ref_envio = process.new_subject()
  let assert Ok(filas) = fila_midia.iniciar_todas()
  let assert Ok(met) = metricas.iniciar()

  let portas =
    Portas(
      mensageiro: portas_fake.mensageiro_capturar(ref_envio),
      despachante_ia: portas_fake.despachante_ia_ok("ok"),
      config: portas_fake.config_ok(
        config.Config(
          ..fixtures.config_padrao(),
          chat_id: fixtures.id("tg:887766"),
        ),
      ),
      historico: portas_fake.historico_vazio(),
      fila: filas,
      prompts: portas_fake.prompt_noop(),
      metricas: met,
      usuarios: portas_fake.usuario_noop(),
      grupos: portas_fake.grupo_noop(),
      transacoes: portas_fake.transacao_noop(),
      provedores_config: portas_fake.provedores_config_ok(),
      anti_spam: portas_fake.anti_spam_ok(),
      spammers: portas_fake.spammer_noop(),
      video_contexto: portas_fake.video_contexto_noop(),
      ponte: portas_fake.ponte_inacessivel(),
    )

  let json =
    "{\"ok\":true,\"result\":[{\"update_id\":5001,\"message\":{\"message_id\":10,\"date\":0,\"chat\":{\"id\":887766,\"type\":\"private\"},\"text\":\"/start\"}}]}"

  let assert Ok(updates) = telegram_webhook.extrair_updates(json)
  let novo_offset =
    receptor_telegram.processar_updates(
      updates,
      0,
      portas_fake.telegram_api(Ok(<<>>), process.new_subject()),
      portas,
      atrasadas(),
    )

  // O novo offset deve ser update_id + 1 = 5002
  novo_offset |> should.equal(5002)

  // Deve ter despachado e respondido para o chat tg:887766
  let assert Ok(#(chat_id, texto)) = process.receive(ref_envio, 2000)
  chat_id |> should.equal(fixtures.id("tg:887766"))
  should.be_true(string.contains(texto, "Amélie — Comandos disponíveis"))
}

pub fn despachar_arquivo_muito_grande_notifica_usuario_test() {
  let ref_envio = process.new_subject()
  let assert Ok(filas) = fila_midia.iniciar_todas()
  let assert Ok(met) = metricas.iniciar()

  let portas =
    Portas(
      mensageiro: portas_fake.mensageiro_capturar(ref_envio),
      despachante_ia: portas_fake.despachante_ia_ok("ok"),
      config: portas_fake.config_ok(
        config.Config(
          ..fixtures.config_padrao(),
          chat_id: fixtures.id("tg:887766"),
        ),
      ),
      historico: portas_fake.historico_vazio(),
      fila: filas,
      prompts: portas_fake.prompt_noop(),
      metricas: met,
      usuarios: portas_fake.usuario_noop(),
      grupos: portas_fake.grupo_noop(),
      transacoes: portas_fake.transacao_noop(),
      provedores_config: portas_fake.provedores_config_ok(),
      anti_spam: portas_fake.anti_spam_ok(),
      spammers: portas_fake.spammer_noop(),
      video_contexto: portas_fake.video_contexto_noop(),
      ponte: portas_fake.ponte_inacessivel(),
    )

  let evento =
    telegram_porta.EventoArquivoMuitoGrande(9999, fixtures.id("tg:887766"), 25)
  receptor_telegram.despachar_evento(
    evento,
    portas_fake.telegram_api(Ok(<<>>), process.new_subject()),
    portas,
    atrasadas(),
  )

  let assert Ok(#(chat_id, texto)) = process.receive(ref_envio, 2000)
  chat_id |> should.equal(fixtures.id("tg:887766"))
  should.be_true(string.contains(texto, "limite suportado pelo bot é de 20 MB"))
  should.be_true(string.contains(texto, "25 MB"))
}

fn atrasadas() -> fila_atrasadas.FilaAtrasadas {
  let assert Ok(fila) = fila_atrasadas.iniciar()
  fila
}

fn portas_capturando(ref_envio) -> Portas {
  Portas(
    ..portas_fake.portas_ok(
      config.Config(
        ..fixtures.config_padrao(),
        chat_id: fixtures.id("tg:887766"),
      ),
      "ok",
    ),
    mensageiro: portas_fake.mensageiro_capturar(ref_envio),
  )
}

fn base_telegram() {
  mensagem.Mensagem(
    ..fixtures.mensagem_texto(""),
    chat_id: fixtures.id("tg:887766"),
    remetente: fixtures.id("tg:887766"),
  )
}

pub fn despachar_foto_sinaliza_envio_de_foto_test() {
  let ref_envio = process.new_subject()
  let ref_acoes = process.new_subject()
  let api = portas_fake.telegram_api(Ok(<<255, 216, 255>>), ref_acoes)
  let evento =
    telegram_porta.EventoFotoParaBaixar(7001, base_telegram(), "foto_1")

  receptor_telegram.despachar_evento(
    evento,
    api,
    portas_capturando(ref_envio),
    atrasadas(),
  )

  process.receive(ref_acoes, 2000)
  |> should.equal(Ok(telegram_porta.EnviandoFoto))
}

pub fn despachar_foto_com_falha_no_download_avisa_usuario_test() {
  let ref_envio = process.new_subject()
  let api =
    portas_fake.telegram_api(
      Error(erro.ErroComunicacao("getFile falhou")),
      process.new_subject(),
    )
  let evento =
    telegram_porta.EventoFotoParaBaixar(7002, base_telegram(), "foto_2")

  receptor_telegram.despachar_evento(
    evento,
    api,
    portas_capturando(ref_envio),
    atrasadas(),
  )

  let assert Ok(#(chat_id, texto)) = process.receive(ref_envio, 2000)
  chat_id |> should.equal(fixtures.id("tg:887766"))
  string.contains(texto, "Não consegui baixar a imagem") |> should.be_true
}

// ---------------------------------------------------------------------------
// Updates acumulados enquanto a Amélie estava fora do ar
// ---------------------------------------------------------------------------

pub fn update_atrasado_vai_para_a_fila_serial_test() {
  // A própria fila fica com o teste: o que for enfileirado chega aqui.
  let fila = process.new_subject()
  let ref_acoes = process.new_subject()
  let api = portas_fake.telegram_api(Ok(<<255, 216, 255>>), ref_acoes)
  let base =
    mensagem.Mensagem(
      ..base_telegram(),
      timestamp: sistema.agora_s() - fila_atrasadas.limiar_atraso_s - 60,
    )

  receptor_telegram.despachar_evento(
    telegram_porta.EventoFotoParaBaixar(7003, base, "foto_3"),
    api,
    portas_capturando(process.new_subject()),
    fila,
  )

  let assert Ok(fila_atrasadas.Processar(tarefa)) = process.receive(fila, 500)
  // Nada foi baixado antes de chegar a vez dela na fila.
  process.receive(ref_acoes, 50) |> should.be_error
  tarefa()
  process.receive(ref_acoes, 500)
  |> should.equal(Ok(telegram_porta.EnviandoFoto))
}

pub fn update_no_horario_nao_passa_pela_fila_test() {
  let fila = process.new_subject()
  let ref_acoes = process.new_subject()
  let api = portas_fake.telegram_api(Ok(<<255, 216, 255>>), ref_acoes)

  receptor_telegram.despachar_evento(
    telegram_porta.EventoFotoParaBaixar(7004, base_telegram(), "foto_4"),
    api,
    portas_capturando(process.new_subject()),
    fila,
  )

  process.receive(ref_acoes, 2000)
  |> should.equal(Ok(telegram_porta.EnviandoFoto))
  process.receive(fila, 50) |> should.be_error
}
