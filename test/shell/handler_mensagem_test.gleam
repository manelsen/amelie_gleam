import dominio/erro
import gleam/erlang/process
import gleeunit/should
import helpers/fixtures
import helpers/portas_fake
import shell/fila_midia
import shell/handler_mensagem
import shell/metricas

fn met() {
  let assert Ok(m) = metricas.iniciar()
  m
}

pub fn handle_texto_simples_retorna_ok_test() {
  let msg = fixtures.mensagem_texto("Olá!")
  let portas =
    portas_fake.portas_ok(fixtures.config_padrao(), "Olá! Posso ajudar.")
  let result = handler_mensagem.handle(msg, portas)
  result |> should.be_ok
}

pub fn handle_texto_envia_para_whatsapp_test() {
  let ref = process.new_subject()
  let cfg = fixtures.config_padrao()
  let msg = fixtures.mensagem_texto("teste")
  let fila = case fila_midia.iniciar_todas() {
    Ok(f) -> f
    Error(_) -> panic as "fila"
  }
  let portas =
    handler_mensagem.Portas(
      whatsapp: portas_fake.whatsapp_capturar(ref),
      ia: portas_fake.ia_ok("resposta esperada"),
      config: portas_fake.config_ok(cfg),
      historico: portas_fake.historico_vazio(),
      fila: fila,
      prompts: portas_fake.prompt_noop(),
      metricas: met(),
      usuarios: portas_fake.usuario_noop(),
      grupos: portas_fake.grupo_noop(),
    )
  let _ = handler_mensagem.handle(msg, portas)
  // Verifica que whatsapp recebeu a mensagem
  let received = process.receive(ref, 1000)
  received |> should.be_ok
  let assert Ok(#(chat_id, texto)) = received
  chat_id |> should.equal(fixtures.chat_id())
  texto |> should.equal("resposta esperada")
}

pub fn handle_erro_config_retorna_erro_test() {
  let msg = fixtures.mensagem_texto("Olá")
  let fila = case fila_midia.iniciar_todas() {
    Ok(f) -> f
    Error(_) -> panic as "fila"
  }
  let portas =
    handler_mensagem.Portas(
      whatsapp: portas_fake.whatsapp_ok(),
      ia: portas_fake.ia_ok("ok"),
      config: portas_fake.config_erro(erro.ErroBancoDados("DB offline")),
      historico: portas_fake.historico_vazio(),
      fila: fila,
      prompts: portas_fake.prompt_noop(),
      metricas: met(),
      usuarios: portas_fake.usuario_noop(),
      grupos: portas_fake.grupo_noop(),
    )
  let result = handler_mensagem.handle(msg, portas)
  result |> should.be_error
}

pub fn handle_erro_ia_retorna_erro_test() {
  let msg = fixtures.mensagem_texto("Olá")
  let fila = case fila_midia.iniciar_todas() {
    Ok(f) -> f
    Error(_) -> panic as "fila"
  }
  let portas =
    handler_mensagem.Portas(
      whatsapp: portas_fake.whatsapp_ok(),
      ia: portas_fake.ia_erro(erro.ErroIA("timeout")),
      config: portas_fake.config_ok(fixtures.config_padrao()),
      historico: portas_fake.historico_vazio(),
      fila: fila,
      prompts: portas_fake.prompt_noop(),
      metricas: met(),
      usuarios: portas_fake.usuario_noop(),
      grupos: portas_fake.grupo_noop(),
    )
  let result = handler_mensagem.handle(msg, portas)
  result |> should.be_error
}

pub fn handle_imagem_enfileira_midia_test() {
  let msg = fixtures.mensagem_imagem()
  let portas = portas_fake.portas_ok(fixtures.config_padrao(), "ok")
  let result = handler_mensagem.handle(msg, portas)
  result |> should.be_ok
}

pub fn handle_imagem_desativada_retorna_ok_test() {
  let msg = fixtures.mensagem_imagem()
  let portas = portas_fake.portas_ok(fixtures.config_midia_off(), "ok")
  let result = handler_mensagem.handle(msg, portas)
  result |> should.be_ok
}
