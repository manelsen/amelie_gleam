import core/processador
import dominio/acao.{
  BaixarVideoUrlEDescrever, BuscarUrlEResponder, EnfileirarMidia, EnviarResposta,
  EnviarTexto, MidiaAudio, MidiaImagem, MidiaVideo, NaoResponder,
}
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

pub fn processar_texto_longo_test() {
  let texto_longo = string.repeat("a", 4097)
  let msg = fixtures.mensagem_texto(texto_longo)
  let cfg = fixtures.config_padrao()
  let result = processador.processar(msg, cfg, [])
  result |> should.be_ok
  let assert Ok([EnviarTexto(para: _, corpo: prompt)]) = result
  string.contains(prompt, texto_longo) |> should.be_true
}

pub fn processar_comando_ponto_no_texto_test() {
  let msg = fixtures.mensagem_texto(".ajuda")
  let cfg = fixtures.config_padrao()
  let result = processador.processar(msg, cfg, [])
  result |> should.be_ok
  // Comandos retornam EnviarResposta (direto, sem IA)
  let assert Ok([EnviarResposta(_, _)]) = result
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
  let msg = mensagem.Mensagem(..fixtures.mensagem_texto("teste"), remetente: "")
  let cfg = fixtures.config_padrao()
  let result = processador.processar(msg, cfg, [])
  result |> should.be_error
}

// ---------------------------------------------------------------------------
// Filtragem de mensagens próprias e de grupo
// ---------------------------------------------------------------------------

pub fn processar_mensagem_propria_retorna_nao_responder_test() {
  // remetente terminando em ":bot" é self-message
  let msg =
    mensagem.Mensagem(
      ..fixtures.mensagem_texto("echo"),
      remetente: "bot@c.us:bot",
    )
  let cfg = fixtures.config_padrao()
  let result = processador.processar(msg, cfg, [])
  result |> should.be_ok
  let assert Ok([acao.NaoResponder]) = result
}

pub fn processar_grupo_sem_mencao_ignora_test() {
  let msg =
    mensagem.Mensagem(
      ..fixtures.mensagem_texto("Oie pessoal"),
      em_grupo: True,
      menciona_bot: False,
    )
  let cfg = fixtures.config_padrao()
  let result = processador.processar(msg, cfg, [])
  result |> should.be_ok
  let assert Ok([acao.NaoResponder]) = result
}

pub fn processar_grupo_com_mencao_processa_test() {
  let msg =
    mensagem.Mensagem(
      ..fixtures.mensagem_texto("@amelie como está?"),
      em_grupo: True,
      menciona_bot: True,
    )
  let cfg = fixtures.config_padrao()
  let result = processador.processar(msg, cfg, [])
  result |> should.be_ok
  let assert Ok([EnviarTexto(_, _)]) = result
}

// ---------------------------------------------------------------------------
// URLs de vídeo
// ---------------------------------------------------------------------------

pub fn processar_url_tiktok_video_ativo_test() {
  let msg =
    fixtures.mensagem_texto("https://www.tiktok.com/@user/video/123456789")
  let cfg = fixtures.config_padrao()
  let result = processador.processar(msg, cfg, [])
  result |> should.be_ok
  let assert Ok([BaixarVideoUrlEDescrever(_, _)]) = result
}

pub fn processar_url_youtube_shorts_video_ativo_test() {
  let msg = fixtures.mensagem_texto("https://youtube.com/shorts/abcdefgh")
  let cfg = fixtures.config_padrao()
  let result = processador.processar(msg, cfg, [])
  result |> should.be_ok
  let assert Ok([BaixarVideoUrlEDescrever(_, _)]) = result
}

pub fn processar_url_youtube_live_video_ativo_test() {
  let msg =
    fixtures.mensagem_texto(
      "Olha isso: https://www.youtube.com/live/abcdefgh?si=123.",
    )
  let cfg = fixtures.config_padrao()
  let result = processador.processar(msg, cfg, [])
  result |> should.be_ok
  let assert Ok([BaixarVideoUrlEDescrever(_, url)]) = result
  url |> should.equal("https://www.youtube.com/live/abcdefgh?si=123")
}

pub fn processar_url_youtube_mobile_video_ativo_test() {
  let msg = fixtures.mensagem_texto("https://m.youtube.com/watch?v=abcdefgh")
  let cfg = fixtures.config_padrao()
  let result = processador.processar(msg, cfg, [])
  result |> should.be_ok
  let assert Ok([BaixarVideoUrlEDescrever(_, _)]) = result
}

pub fn processar_url_instagram_reels_video_ativo_test() {
  let msg = fixtures.mensagem_texto("https://www.instagram.com/reels/ABC123/")
  let cfg = fixtures.config_padrao()
  let result = processador.processar(msg, cfg, [])
  result |> should.be_ok
  let assert Ok([BaixarVideoUrlEDescrever(_, _)]) = result
}

pub fn processar_url_instagram_stories_video_ativo_test() {
  let msg =
    fixtures.mensagem_texto("https://www.instagram.com/stories/usuario/123456/")
  let cfg = fixtures.config_padrao()
  let result = processador.processar(msg, cfg, [])
  result |> should.be_ok
  let assert Ok([BaixarVideoUrlEDescrever(_, _)]) = result
}

pub fn processar_url_video_inativo_cai_em_buscar_url_test() {
  let msg =
    fixtures.mensagem_texto("https://www.tiktok.com/@user/video/123456789")
  let cfg = fixtures.config_midia_off()
  let result = processador.processar(msg, cfg, [])
  result |> should.be_ok
  let assert Ok([BuscarUrlEResponder(_, _, _)]) = result
}

pub fn processar_url_comum_nao_e_video_test() {
  let msg = fixtures.mensagem_texto("https://example.com/artigo")
  let cfg = fixtures.config_padrao()
  let result = processador.processar(msg, cfg, [])
  result |> should.be_ok
  let assert Ok([BuscarUrlEResponder(_, _, _)]) = result
}

pub fn processar_grupo_comando_sem_mencao_passa_test() {
  // Comandos (começando com ".") devem passar mesmo em grupo sem menção
  let msg =
    mensagem.Mensagem(
      ..fixtures.mensagem_texto(".ajuda"),
      em_grupo: True,
      menciona_bot: False,
    )
  let cfg = fixtures.config_padrao()
  let result = processador.processar(msg, cfg, [])
  result |> should.be_ok
  let assert Ok([acao.EnviarResposta(_, _)]) = result
}
