import core/validacao
import gleam/string
import gleeunit/should

pub fn normalizar_remove_acentos_test() {
  validacao.normalizar_nome_comando("áudio")
  |> should.equal("audio")
}

pub fn normalizar_remove_acento_maiusculo_test() {
  validacao.normalizar_nome_comando("Áudio")
  |> should.equal("audio")
}

pub fn normalizar_trim_test() {
  validacao.normalizar_nome_comando("  audio  ")
  |> should.equal("audio")
}

pub fn normalizar_sem_acento_test() {
  validacao.normalizar_nome_comando("reset")
  |> should.equal("reset")
}

pub fn normalizar_video_com_acento_test() {
  validacao.normalizar_nome_comando("vídeo")
  |> should.equal("video")
}

pub fn normalizar_cedilha_test() {
  validacao.normalizar_nome_comando("ação")
  |> should.equal("acao")
}

pub fn parsear_comando_com_espaco_apos_ponto_test() {
  validacao.parsear_comando(". audio on")
  |> should.be_ok
  |> should.equal(#("audio", "on"))
}

pub fn parsear_comando_com_acento_test() {
  validacao.parsear_comando(".áudio")
  |> should.be_ok
  |> should.equal(#("audio", ""))
}

pub fn parsear_comando_espaco_e_acento_test() {
  validacao.parsear_comando(". Áudio on")
  |> should.be_ok
  |> should.equal(#("audio", "on"))
}

pub fn parsear_comando_espaco_e_acento_sem_args_test() {
  validacao.parsear_comando(". Áudio")
  |> should.be_ok
  |> should.equal(#("audio", ""))
}

pub fn parsear_comando_video_com_acento_test() {
  validacao.parsear_comando(".vídeo off")
  |> should.be_ok
  |> should.equal(#("video", "off"))
}

pub fn parsear_comando_normal_inalterado_test() {
  validacao.parsear_comando(".ajuda")
  |> should.be_ok
  |> should.equal(#("ajuda", ""))
}

// --- Comandos sem ponto ---

pub fn sem_ponto_audio_test() {
  validacao.parsear_comando("audio")
  |> should.be_ok
  |> should.equal(#("audio", ""))
}

pub fn sem_ponto_audio_com_acento_test() {
  validacao.parsear_comando("Áudio")
  |> should.be_ok
  |> should.equal(#("audio", ""))
}

pub fn sem_ponto_audio_on_test() {
  validacao.parsear_comando("audio on")
  |> should.be_ok
  |> should.equal(#("audio", "on"))
}

pub fn sem_ponto_audio_acento_on_test() {
  validacao.parsear_comando("Áudio on")
  |> should.be_ok
  |> should.equal(#("audio", "on"))
}

pub fn sem_ponto_ajuda_test() {
  validacao.parsear_comando("ajuda")
  |> should.be_ok
  |> should.equal(#("ajuda", ""))
}

pub fn sem_ponto_reset_test() {
  validacao.parsear_comando("Reset")
  |> should.be_ok
  |> should.equal(#("reset", ""))
}

pub fn sem_ponto_video_acento_test() {
  validacao.parsear_comando("Vídeo off")
  |> should.be_ok
  |> should.equal(#("video", "off"))
}

pub fn sem_ponto_cego_test() {
  validacao.parsear_comando("cego")
  |> should.be_ok
  |> should.equal(#("cego", ""))
}

pub fn sem_ponto_modelo_com_args_test() {
  validacao.parsear_comando("modelo gemini/gemini-2.5-pro")
  |> should.be_ok
  |> should.equal(#("modelo", "gemini/gemini-2.5-pro"))
}

pub fn sem_ponto_texto_normal_nao_e_comando_test() {
  validacao.parsear_comando("olá tudo bem?")
  |> should.be_error
}

pub fn sem_ponto_texto_com_palavra_comando_no_meio_test() {
  validacao.parsear_comando("o audio ficou bom")
  |> should.be_error
}

pub fn validar_texto_longo_retorna_ok_test() {
  let texto_longo = string.repeat("a", 4097)

  validacao.validar_texto(texto_longo)
  |> should.be_ok
  |> should.equal(texto_longo)
}
