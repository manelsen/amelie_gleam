import adaptadores/telegram_webhook
import dominio/config
import gleam/erlang/process
import gleam/string
import gleeunit/should
import helpers/fixtures
import helpers/portas_fake
import shell/fila_midia
import shell/handler_mensagem.{Portas}
import shell/metricas
import shell/telegram_poller

pub fn extrair_updates_json_test() {
  let json =
    "{\"ok\":true,\"result\":[{\"update_id\":5001,\"message\":{\"message_id\":10,\"date\":0,\"chat\":{\"id\":887766,\"type\":\"private\"},\"text\":\"/start\"}},{\"update_id\":5002,\"message\":{\"message_id\":11,\"date\":0,\"chat\":{\"id\":-10099,\"type\":\"group\"},\"text\":\"no grupo\"}}]}"

  let assert Ok(updates) = telegram_webhook.extrair_updates(json)
  let assert [u1, u2] = updates

  case u1 {
    telegram_webhook.EventoMensagemPronta(id, msg) -> {
      id |> should.equal(5001)
      msg.chat_id |> should.equal("tg:887766")
    }
    _ -> should.fail()
  }

  // Grupo deve ser ignorado (EventoIgnorado)
  case u2 {
    telegram_webhook.EventoIgnorado(id) -> id |> should.equal(5002)
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
      ia_dispatcher: portas_fake.ia_dispatcher_ok("ok"),
      config: portas_fake.config_ok(
        config.Config(..fixtures.config_padrao(), chat_id: "tg:887766"),
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
    "{\"ok\":true,\"result\":[{\"update_id\":5001,\"message\":{\"message_id\":10,\"date\":0,\"chat\":{\"id\":887766,\"type\":\"private\"},\"text\":\"/start\"}}]}"

  let assert Ok(updates) = telegram_webhook.extrair_updates(json)
  let novo_offset =
    telegram_poller.processar_updates(updates, 0, "fake_token", portas)

  // O novo offset deve ser update_id + 1 = 5002
  novo_offset |> should.equal(5002)

  // Deve ter despachado e respondido para o chat tg:887766
  let assert Ok(#(chat_id, texto)) = process.receive(ref_envio, 2500)
  chat_id |> should.equal("tg:887766")
  should.be_true(string.contains(texto, "Amélie — Comandos disponíveis"))
}

pub fn despachar_arquivo_muito_grande_notifica_usuario_test() {
  let ref_envio = process.new_subject()
  let assert Ok(filas) = fila_midia.iniciar_todas()
  let assert Ok(met) = metricas.iniciar()

  let portas =
    Portas(
      mensageiro: portas_fake.mensageiro_capturar(ref_envio),
      ia_dispatcher: portas_fake.ia_dispatcher_ok("ok"),
      config: portas_fake.config_ok(
        config.Config(..fixtures.config_padrao(), chat_id: "tg:887766"),
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

  let evento = telegram_webhook.EventoArquivoMuitoGrande(9999, "tg:887766", 25)
  telegram_poller.despachar_evento(evento, "fake_token", portas)

  let assert Ok(#(chat_id, texto)) = process.receive(ref_envio, 2000)
  chat_id |> should.equal("tg:887766")
  should.be_true(string.contains(texto, "limite suportado pelo bot é de 20 MB"))
  should.be_true(string.contains(texto, "25 MB"))
}
