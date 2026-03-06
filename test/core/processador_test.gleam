import core/processador
import dominio/acao.{EnfileirarMidia, EnviarTexto, MidiaAudio, MidiaImagem, MidiaVideo, NaoResponder}
import dominio/erro
import dominio/mensagem
import gleam/string
import gleeunit/should
import helpers/fixtures

pub fn processar_texto_simples_test() {
  let msg = fixtures.mensagem_texto("Olá, tudo bem?")
  let cfg = fixtures.config_padrao()
  let result = processador.processar(msg, cfg, [])
  result |> should.be_ok
  let assert Ok([EnviarTexto(para: _, corpo: prompt)]) = result
  string.contains(prompt, "Olá, tudo bem?") |> should.be_true
}

pub fn processar_texto_com_historico_test() {
  let msg = fixtures.mensagem_texto("Como vai?")
  let cfg = fixtures.config_padrao()
  let hist = fixtures.historico_com_turnos()
  let result = processador.processar(msg, cfg, hist)
  result |> should.be_ok
  let assert Ok([EnviarTexto(para: _, corpo: prompt)]) = result
  string.contains(prompt, "Olá") |> should.be_true
}

pub fn processar_texto_vazio_retorna_erro_test() {
  let msg = fixtures.mensagem_texto("   ")
  let cfg = fixtures.config_padrao()
  let result = processador.processar(msg, cfg, [])
  result |> should.be_error
}

pub fn processar_comando_ponto_no_texto_test() {
  let msg = fixtures.mensagem_texto(".ajuda")
  let cfg = fixtures.config_padrao()
  let result = processador.processar(msg, cfg, [])
  result |> should.be_ok
  let assert Ok([EnviarTexto(_, _)]) = result
}

pub fn processar_imagem_ativa_test() {
  let msg = fixtures.mensagem_imagem()
  let cfg = fixtures.config_padrao()
  let result = processador.processar(msg, cfg, [])
  result |> should.be_ok
  let assert Ok([EnfileirarMidia(_, MidiaImagem)]) = result
}

pub fn processar_imagem_desativada_test() {
  let msg = fixtures.mensagem_imagem()
  let cfg = fixtures.config_midia_off()
  let result = processador.processar(msg, cfg, [])
  result |> should.be_ok
  let assert Ok([NaoResponder]) = result
}

pub fn processar_audio_ativo_test() {
  let msg = fixtures.mensagem_audio()
  let cfg = fixtures.config_padrao()
  let result = processador.processar(msg, cfg, [])
  result |> should.be_ok
  let assert Ok([EnfileirarMidia(_, MidiaAudio)]) = result
}

pub fn processar_video_ativo_test() {
  let msg = fixtures.mensagem_video()
  let cfg = fixtures.config_padrao()
  let result = processador.processar(msg, cfg, [])
  result |> should.be_ok
  let assert Ok([EnfileirarMidia(_, MidiaVideo)]) = result
}

pub fn processar_chat_id_vazio_retorna_erro_test() {
  let msg = mensagem.Mensagem(..fixtures.mensagem_texto("teste"), chat_id: "")
  let cfg = fixtures.config_padrao()
  let result = processador.processar(msg, cfg, [])
  result |> should.be_error
  let assert Error(erro.ErroValidacao("chat_id", _)) = result
}

pub fn processar_remetente_vazio_retorna_erro_test() {
  let msg =
    mensagem.Mensagem(..fixtures.mensagem_texto("teste"), remetente: "")
  let cfg = fixtures.config_padrao()
  let result = processador.processar(msg, cfg, [])
  result |> should.be_error
}
