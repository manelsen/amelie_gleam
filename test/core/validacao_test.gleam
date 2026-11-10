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

pub fn sem_ponto_frase_com_comando_no_inicio_nao_e_comando_test() {
  validacao.parsear_comando("Reset minha conversa, por favor")
  |> should.be_error
  validacao.parsear_comando("imagem bonita")
  |> should.be_error
  validacao.parsear_comando("Áudio está ruim")
  |> should.be_error
  validacao.parsear_comando("Video https://youtu.be/abc")
  |> should.be_error
  validacao.parsear_comando("resumo do áudio")
  |> should.be_error
  validacao.parsear_comando("cego, descreve esta foto")
  |> should.be_error
  validacao.parsear_comando("modelo novo é melhor")
  |> should.be_error
}

pub fn sem_ponto_argumentos_validos_continuam_test() {
  validacao.parsear_comando("parear 5531999990000")
  |> should.equal(Ok(#("parear", "5531999990000")))
  validacao.parsear_comando("doc OFF")
  |> should.equal(Ok(#("doc", "OFF")))
}

pub fn sem_ponto_telefone_com_espacos_test() {
  validacao.parsear_comando("parear 55 31 99999-0000")
  |> should.equal(Ok(#("parear", "55 31 99999-0000")))
  validacao.parsear_comando("reset_whatsapp +55 (31) 99999-0000")
  |> should.equal(Ok(#("reset_whatsapp", "+55 (31) 99999-0000")))
  validacao.parsear_comando("unban 55 31 99999-0000")
  |> should.equal(Ok(#("unban", "55 31 99999-0000")))
}

pub fn sem_ponto_parear_sem_telefone_e_conversa_test() {
  validacao.parsear_comando("parear meu celular")
  |> should.be_error
  validacao.parsear_comando("reset_whatsapp agora por favor")
  |> should.be_error
}

pub fn com_ponto_aceita_qualquer_argumento_test() {
  validacao.parsear_comando(".reset minha conversa")
  |> should.equal(Ok(#("reset", "minha conversa")))
}
