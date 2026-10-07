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
