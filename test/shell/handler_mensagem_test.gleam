import dominio/erro
import dominio/mensagem.{Mensagem}
import gleam/erlang/process
import gleam/int
import gleam/option
import gleam/string
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

fn spam() {
  portas_fake.anti_spam_ok()
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
      mensageiro: portas_fake.mensageiro_capturar(ref),
      ia_dispatcher: portas_fake.ia_dispatcher_ok("resposta esperada"),
      config: portas_fake.config_ok(cfg),
      historico: portas_fake.historico_vazio(),
      fila: fila,
      prompts: portas_fake.prompt_noop(),
      metricas: met(),
      usuarios: portas_fake.usuario_noop(),
      grupos: portas_fake.grupo_noop(),
      transacoes: portas_fake.transacao_noop(),
      providers_config: portas_fake.providers_config_ok(),
      anti_spam: spam(),
    )
  let _ = handler_mensagem.handle(msg, portas)
  // Verifica que whatsapp recebeu a mensagem
  let received = process.receive(ref, 1000)
  received |> should.be_ok
  let assert Ok(#(chat_id, texto)) = received
  chat_id |> should.equal(fixtures.chat_id())
  texto |> should.equal("resposta esperada")
}

pub fn handle_texto_marca_transacao_entregue_test() {
  let ref = process.new_subject()
  let msg = fixtures.mensagem_texto("teste")
  let fila = case fila_midia.iniciar_todas() {
    Ok(f) -> f
    Error(_) -> panic as "fila"
  }
  let portas =
    handler_mensagem.Portas(
      mensageiro: portas_fake.mensageiro_ok(),
      ia_dispatcher: portas_fake.ia_dispatcher_ok("resposta esperada"),
      config: portas_fake.config_ok(fixtures.config_padrao()),
      historico: portas_fake.historico_vazio(),
      fila: fila,
      prompts: portas_fake.prompt_noop(),
      metricas: met(),
      usuarios: portas_fake.usuario_noop(),
      grupos: portas_fake.grupo_noop(),
      transacoes: portas_fake.transacao_capturar(ref),
      providers_config: portas_fake.providers_config_ok(),
      anti_spam: spam(),
    )
  let result = handler_mensagem.handle(msg, portas)
  result |> should.be_ok
  let assert Ok(portas_fake.Registrada(_)) = process.receive(ref, 1000)
  let assert Ok(portas_fake.MarcadaEntregue(1)) = process.receive(ref, 1000)
}

pub fn handle_texto_falha_atualiza_transacao_test() {
  let ref = process.new_subject()
  let msg = fixtures.mensagem_texto("teste")
  let fila = case fila_midia.iniciar_todas() {
    Ok(f) -> f
    Error(_) -> panic as "fila"
  }
  let portas =
    handler_mensagem.Portas(
      mensageiro: portas_fake.mensageiro_erro(erro.ErroComunicacao("offline")),
      ia_dispatcher: portas_fake.ia_dispatcher_ok("resposta esperada"),
      config: portas_fake.config_ok(fixtures.config_padrao()),
      historico: portas_fake.historico_vazio(),
      fila: fila,
      prompts: portas_fake.prompt_noop(),
      metricas: met(),
      usuarios: portas_fake.usuario_noop(),
      grupos: portas_fake.grupo_noop(),
      transacoes: portas_fake.transacao_capturar(ref),
      providers_config: portas_fake.providers_config_ok(),
      anti_spam: spam(),
    )
  let result = handler_mensagem.handle(msg, portas)
  result |> should.be_error
  let assert Ok(portas_fake.Registrada(_)) = process.receive(ref, 1000)
  let assert Ok(portas_fake.ErroAtualizado(1, _, 1)) =
    process.receive(ref, 1000)
}

pub fn handle_erro_config_retorna_erro_test() {
  let msg = fixtures.mensagem_texto("Olá")
  let fila = case fila_midia.iniciar_todas() {
    Ok(f) -> f
    Error(_) -> panic as "fila"
  }
  let portas =
    handler_mensagem.Portas(
      mensageiro: portas_fake.mensageiro_ok(),
      ia_dispatcher: portas_fake.ia_dispatcher_ok("ok"),
      config: portas_fake.config_erro(erro.ErroBancoDados("DB offline")),
      historico: portas_fake.historico_vazio(),
      fila: fila,
      prompts: portas_fake.prompt_noop(),
      metricas: met(),
      usuarios: portas_fake.usuario_noop(),
      grupos: portas_fake.grupo_noop(),
      transacoes: portas_fake.transacao_noop(),
      providers_config: portas_fake.providers_config_ok(),
      anti_spam: spam(),
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
      mensageiro: portas_fake.mensageiro_ok(),
      ia_dispatcher: portas_fake.ia_dispatcher_erro(erro.ErroIA("timeout")),
      config: portas_fake.config_ok(fixtures.config_padrao()),
      historico: portas_fake.historico_vazio(),
      fila: fila,
      prompts: portas_fake.prompt_noop(),
      metricas: met(),
      usuarios: portas_fake.usuario_noop(),
      grupos: portas_fake.grupo_noop(),
      transacoes: portas_fake.transacao_noop(),
      providers_config: portas_fake.providers_config_ok(),
      anti_spam: spam(),
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

pub fn extrair_trace_id_test() {
  let msg_com_id = fixtures.mensagem_texto("com id")
  handler_mensagem.extrair_trace_id(msg_com_id)
  |> should.equal("MSG001")

  let msg_sem_id = Mensagem(..msg_com_id, message_id: option.None)
  handler_mensagem.extrair_trace_id(msg_sem_id)
  |> should.equal(
    "req_" <> int.to_string(msg_sem_id.timestamp) <> "_" <> msg_sem_id.remetente,
  )
}

pub fn handle_com_rate_limit_envia_aviso_ao_usuario_test() {
  let ref = process.new_subject()
  let portas =
    handler_mensagem.Portas(
      mensageiro: portas_fake.mensageiro_capturar(ref),
      ia_dispatcher: portas_fake.ia_dispatcher_ok("resposta"),
      config: portas_fake.config_ok(fixtures.config_padrao()),
      historico: portas_fake.historico_vazio(),
      fila: fila_midia.iniciar_todas() |> should.be_ok,
      prompts: portas_fake.prompt_noop(),
      metricas: met(),
      usuarios: portas_fake.usuario_noop(),
      grupos: portas_fake.grupo_noop(),
      transacoes: portas_fake.transacao_noop(),
      providers_config: portas_fake.providers_config_ok(),
      anti_spam: spam(),
    )

  let img1 =
    Mensagem(..fixtures.mensagem_imagem(), message_id: option.Some("IMG_1"))
  let img2 =
    Mensagem(..fixtures.mensagem_imagem(), message_id: option.Some("IMG_2"))
  let img3 =
    Mensagem(..fixtures.mensagem_imagem(), message_id: option.Some("IMG_3"))

  // Envia 2 imagens consecutivas (2 tokens cada, esgotando os 4 tokens)
  let _ = handler_mensagem.handle(img1, portas)
  let _ = handler_mensagem.handle(img2, portas)

  // 3ª imagem imediata não tem tokens suficientes (quer 2.0, tem 0.0) -> AvisoLimite
  let _ = handler_mensagem.handle(img3, portas)

  // Aguarda e busca a mensagem que contém o aviso de rate limit
  let aviso = buscar_aviso(ref)
  should.be_true(string.contains(aviso, "Calma lá"))
}

fn buscar_aviso(ref: process.Subject(#(String, String))) -> String {
  let assert Ok(#(_chat_id, texto)) = process.receive(ref, 1000)
  case string.contains(texto, "Calma lá") {
    True -> texto
    False -> buscar_aviso(ref)
  }
}

pub fn handle_com_unban_admin_test() {
  let ref = process.new_subject()
  let spam_actor = spam()
  let portas =
    handler_mensagem.Portas(
      mensageiro: portas_fake.mensageiro_capturar(ref),
      ia_dispatcher: portas_fake.ia_dispatcher_ok("resposta"),
      config: portas_fake.config_ok(fixtures.config_padrao()),
      historico: portas_fake.historico_vazio(),
      fila: fila_midia.iniciar_todas() |> should.be_ok,
      prompts: portas_fake.prompt_noop(),
      metricas: met(),
      usuarios: portas_fake.usuario_noop(),
      grupos: portas_fake.grupo_noop(),
      transacoes: portas_fake.transacao_noop(),
      providers_config: portas_fake.providers_config_ok(),
      anti_spam: spam_actor,
    )

  // Mensagem de admin executando .unban
  let msg = fixtures.mensagem_comando("unban", "551199999999")
  let _ = handler_mensagem.handle(msg, portas)

  // Não sendo admin configurado no env, rejeita com comando restrito
  let assert Ok(#(_chat_id, texto)) = process.receive(ref, 1000)
  should.be_true(string.contains(texto, "restrito ao administrador"))
}
