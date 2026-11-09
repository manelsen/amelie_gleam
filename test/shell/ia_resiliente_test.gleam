// Testes de quais erros de IA contam para o disjuntor.

import dominio/erro
import gleeunit/should
import helpers/portas_fake
import shell/cache_ia
import shell/disjuntor.{Config, Fechado}
import shell/ia_resiliente

fn porta_com_erro(e: erro.Erro) {
  let assert Ok(cb) =
    disjuntor.iniciar_com_config(Config(
      limite_falhas: 2,
      reset_ms: 60_000,
      timeout_sondagem_ms: 1000,
    ))
  let assert Ok(cache) = cache_ia.iniciar()
  #(ia_resiliente.envolver(portas_fake.ia_erro(e), cb, cache), cb)
}

pub fn erro_da_requisicao_nao_abre_o_circuito_test() {
  let #(ia, cb) = porta_com_erro(erro.ErroIA("Gemini retornou status 400"))

  ia.processar_imagem(<<>>, "image/png", "p", "m") |> should.be_error
  ia.processar_imagem(<<>>, "image/png", "p", "m") |> should.be_error
  ia.processar_imagem(<<>>, "image/png", "p", "m") |> should.be_error

  disjuntor.obter_estado(cb) |> should.equal(Fechado(0))
  disjuntor.pode_executar(cb) |> should.be_true
}

pub fn erro_5xx_conta_para_o_disjuntor_test() {
  let #(ia, cb) = porta_com_erro(erro.ErroIA("Gemini retornou status 500"))

  ia.processar_imagem(<<>>, "image/png", "p", "m") |> should.be_error

  disjuntor.obter_estado(cb) |> should.equal(Fechado(1))
}

pub fn classifica_falhas_do_servico_test() {
  ia_resiliente.e_falha_servico(erro.ErroIA("rate limit Gemini"))
  |> should.be_true
  ia_resiliente.e_falha_servico(erro.ErroIA("OpenRouter retornou status 503"))
  |> should.be_true
  ia_resiliente.e_falha_servico(erro.ErroTimeout("gerar_texto"))
  |> should.be_true
  ia_resiliente.e_falha_servico(erro.ErroIA(
    "formato de resposta Gemini inesperado",
  ))
  |> should.be_false
  ia_resiliente.e_falha_servico(erro.ErroIA("Gemini retornou status 400"))
  |> should.be_false
}

pub fn classifica_falhas_de_upload_test() {
  ia_resiliente.e_falha_servico(erro.ErroUpload(
    "upload status 503: indisponível",
  ))
  |> should.be_true
  ia_resiliente.e_falha_servico(erro.ErroUpload("upload status 429: quota"))
  |> should.be_true
  ia_resiliente.e_falha_servico(erro.ErroUpload("{failed_connect,[]}"))
  |> should.be_true
  ia_resiliente.e_falha_servico(erro.ErroUpload("timeout"))
  |> should.be_true
  ia_resiliente.e_falha_servico(erro.ErroUpload(
    "timeout aguardando vídeo ficar ativo",
  ))
  |> should.be_true
  ia_resiliente.e_falha_servico(erro.ErroUpload("upload status 400: inválido"))
  |> should.be_false
  ia_resiliente.e_falha_servico(erro.ErroUpload(
    "OpenRouter não suporta upload direto de vídeo",
  ))
  |> should.be_false
  ia_resiliente.e_falha_servico(erro.ErroUpload(
    "status inesperado ao ativar vídeo: 403",
  ))
  |> should.be_false
}
