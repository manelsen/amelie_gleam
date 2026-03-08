import core/prompt/builder
import dominio/config.{Longo}
import dominio/mensagem
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import helpers/fixtures

pub fn montar_inclui_texto_usuario_test() {
  let cfg = fixtures.config_padrao()
  let prompt = builder.montar("Qual é a capital do Brasil?", cfg, [])
  string.contains(prompt, "Qual é a capital do Brasil?") |> should.be_true
}

pub fn montar_inclui_prompt_padrao_test() {
  let cfg = fixtures.config_padrao()
  let prompt = builder.montar("teste", cfg, [])
  string.contains(prompt, "Amélie") |> should.be_true
}

pub fn montar_inclui_idioma_test() {
  let cfg = fixtures.config_padrao()
  let prompt = builder.montar("teste", cfg, [])
  string.contains(prompt, "pt-BR") |> should.be_true
}

pub fn montar_usa_prompt_personalizado_test() {
  let cfg = fixtures.config_com_prompt()
  let prompt = builder.montar("teste", cfg, [])
  string.contains(prompt, "assistente de testes") |> should.be_true
}

pub fn montar_inclui_historico_test() {
  let cfg = fixtures.config_padrao()
  let hist = fixtures.historico_com_turnos()
  let prompt = builder.montar("nova pergunta", cfg, hist)
  string.contains(prompt, "Olá") |> should.be_true
  string.contains(prompt, "nova pergunta") |> should.be_true
}

pub fn montar_historico_vazio_sem_separador_extra_test() {
  let cfg = fixtures.config_padrao()
  let prompt = builder.montar("só isso", cfg, [])
  string.starts_with(prompt, "\n\n") |> should.be_false
}

pub fn montar_para_imagem_sem_prompt_personalizado_test() {
  let cfg = fixtures.config_padrao()
  let prompt = builder.montar_para_imagem(cfg, None)
  string.contains(prompt, "imagem") |> should.be_true
}

pub fn montar_para_imagem_com_prompt_personalizado_test() {
  let cfg = fixtures.config_com_prompt()
  let prompt = builder.montar_para_imagem(cfg, None)
  string.contains(prompt, "assistente de testes") |> should.be_true
  string.contains(prompt, "imagem") |> should.be_true
}

pub fn montar_para_audio_test() {
  let cfg = fixtures.config_padrao()
  let prompt = builder.montar_para_audio(cfg)
  string.contains(prompt, "áudio") |> should.be_true
}

pub fn montar_para_video_test() {
  let cfg = fixtures.config_padrao()
  let prompt = builder.montar_para_video(cfg, None)
  string.contains(prompt, "vídeo") |> should.be_true
}

pub fn montar_para_documento_sem_prompt_personalizado_test() {
  let cfg = fixtures.config_padrao()
  let prompt = builder.montar_para_documento(cfg, None)
  string.contains(prompt, "documento") |> should.be_true
}

pub fn montar_para_documento_com_prompt_personalizado_test() {
  let cfg = fixtures.config_com_prompt()
  let prompt = builder.montar_para_documento(cfg, None)
  string.contains(prompt, "assistente de testes") |> should.be_true
  string.contains(prompt, "documento") |> should.be_true
}

// Testes para modo de descrição
pub fn montar_para_imagem_modo_longo_test() {
  let cfg = config.Config(..fixtures.config_padrao(), modo_descricao: Longo)
  let prompt = builder.montar_para_imagem(cfg, None)
  string.contains(prompt, "completa e detalhada") |> should.be_true
}

pub fn montar_para_imagem_modo_curto_test() {
  let cfg = fixtures.config_padrao()  // curto is default
  let prompt = builder.montar_para_imagem(cfg, None)
  string.contains(prompt, "concisa e objetiva") |> should.be_true
}

// Testes para legenda
pub fn montar_para_legenda_test() {
  let cfg = fixtures.config_padrao()
  let prompt = builder.montar_para_legenda(cfg)
  string.contains(prompt, "legendas") |> should.be_true
  string.contains(prompt, "surdas") |> should.be_true
}

// Testes para caption (legenda da mídia)
pub fn montar_para_imagem_com_caption_test() {
  let cfg = fixtures.config_padrao()
  let prompt = builder.montar_para_imagem(cfg, Some("descreva as roupas"))
  string.contains(prompt, "descreva as roupas") |> should.be_true
  string.contains(prompt, "foco em") |> should.be_true
}

pub fn montar_historico_respeita_max_test() {
  let _cfg = fixtures.config_com_prompt()
  let muitos_turnos =
    int.range(from: 20, to: 0, with: [], run: fn(acc, i) { [i, ..acc] })
    |> list.flat_map(fn(i) {
      let s = int.to_string(i)
      [
        mensagem.TurnoUsuario("pergunta " <> s),
        mensagem.TurnoAssistente("resposta " <> s),
      ]
    })
  let prompt = builder.montar("atual", fixtures.config_padrao(), muitos_turnos)
  string.contains(prompt, "pergunta 1\n") |> should.be_false
}
