import core/comando/dispatcher
import dominio/acao.{EnviarTexto, NaoResponder}
import dominio/erro
import gleam/string
import gleeunit/should
import helpers/fixtures

pub fn ajuda_retorna_texto_test() {
  let cfg = fixtures.config_padrao()
  let result = dispatcher.executar("ajuda", "", cfg)
  result |> should.be_ok
  let assert Ok([EnviarTexto(_, texto)]) = result
  string.contains(texto, "Amélie") |> should.be_true
}

pub fn config_sem_args_retorna_config_test() {
  let cfg = fixtures.config_padrao()
  let result = dispatcher.executar("config", "", cfg)
  result |> should.be_ok
  let assert Ok([EnviarTexto(_, texto)]) = result
  string.contains(texto, "gemini") |> should.be_true
}

pub fn config_com_args_retorna_erro_test() {
  let cfg = fixtures.config_padrao()
  let result = dispatcher.executar("config", "foo", cfg)
  result |> should.be_error
}

pub fn reset_retorna_mensagem_test() {
  let cfg = fixtures.config_padrao()
  let result = dispatcher.executar("reset", "", cfg)
  result |> should.be_ok
  let assert Ok([EnviarTexto(_, texto)]) = result
  string.contains(texto, "Histórico") |> should.be_true
}

pub fn audio_on_retorna_nao_responder_test() {
  let cfg = fixtures.config_padrao()
  let result = dispatcher.executar("audio", "on", cfg)
  result |> should.be_ok
  let assert Ok([NaoResponder]) = result
}

pub fn audio_off_retorna_nao_responder_test() {
  let cfg = fixtures.config_padrao()
  let result = dispatcher.executar("audio", "off", cfg)
  result |> should.be_ok
  let assert Ok([NaoResponder]) = result
}

pub fn audio_sem_args_retorna_status_test() {
  let cfg = fixtures.config_padrao()
  let result = dispatcher.executar("audio", "", cfg)
  result |> should.be_ok
  let assert Ok([EnviarTexto(_, texto)]) = result
  string.contains(texto, "audio") |> should.be_true
}

pub fn audio_arg_invalido_retorna_erro_test() {
  let cfg = fixtures.config_padrao()
  let result = dispatcher.executar("audio", "sim", cfg)
  result |> should.be_error
  let assert Error(erro.ErroValidacao("audio", _)) = result
}

pub fn imagem_on_test() {
  let cfg = fixtures.config_padrao()
  let assert Ok([NaoResponder]) = dispatcher.executar("imagem", "on", cfg)
}

pub fn video_on_test() {
  let cfg = fixtures.config_padrao()
  let assert Ok([NaoResponder]) = dispatcher.executar("video", "on", cfg)
}

pub fn doc_on_test() {
  let cfg = fixtures.config_padrao()
  let assert Ok([NaoResponder]) = dispatcher.executar("doc", "on", cfg)
}

pub fn prompt_vazio_retorna_status_test() {
  let cfg = fixtures.config_padrao()
  let result = dispatcher.executar("prompt", "", cfg)
  result |> should.be_ok
  let assert Ok([EnviarTexto(_, texto)]) = result
  string.contains(texto, "Nenhum") |> should.be_true
}

pub fn prompt_reset_retorna_confirmacao_test() {
  let cfg = fixtures.config_padrao()
  let result = dispatcher.executar("prompt", "reset", cfg)
  result |> should.be_ok
  let assert Ok([EnviarTexto(_, texto)]) = result
  string.contains(texto, "removido") |> should.be_true
}

pub fn prompt_novo_retorna_nao_responder_test() {
  let cfg = fixtures.config_padrao()
  let result = dispatcher.executar("prompt", "Você é um bot de testes.", cfg)
  result |> should.be_ok
  let assert Ok([NaoResponder]) = result
}

pub fn comando_desconhecido_retorna_erro_test() {
  let cfg = fixtures.config_padrao()
  let result = dispatcher.executar("xyzzy", "", cfg)
  result |> should.be_error
  let assert Error(erro.ErroComandoDesconhecido("xyzzy")) = result
}
