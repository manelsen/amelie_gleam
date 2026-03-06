import core/prompt/builder
import dominio/mensagem
import gleam/int
import gleam/list
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
  // Não deve ter duplos \n\n no início
  string.starts_with(prompt, "\n\n") |> should.be_false
}

pub fn montar_para_imagem_sem_prompt_personalizado_test() {
  let cfg = fixtures.config_padrao()
  let prompt = builder.montar_para_imagem(cfg)
  string.contains(prompt, "imagem") |> should.be_true
}

pub fn montar_para_imagem_com_prompt_personalizado_test() {
  let cfg = fixtures.config_com_prompt()
  let prompt = builder.montar_para_imagem(cfg)
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
  let prompt = builder.montar_para_video(cfg)
  string.contains(prompt, "vídeo") |> should.be_true
}

pub fn montar_historico_respeita_max_test() {
  let _cfg = fixtures.config_com_prompt()
  // Cria histórico com mais turnos que historico_max
  let muitos_turnos =
    int.range(from: 20, to: 0, with: [], run: fn(acc, i) { [i, ..acc] })
    |> list.flat_map(fn(i) {
      let s = int.to_string(i)
      [
        mensagem.TurnoUsuario("pergunta " <> s),
        mensagem.TurnoAssistente("resposta " <> s),
      ]
    })
  // historico_max = 10 no config_padrao, então apenas últimos 10 turnos
  let prompt = builder.montar("atual", fixtures.config_padrao(), muitos_turnos)
  // "pergunta 1" deve estar fora do limite
  string.contains(prompt, "pergunta 1\n") |> should.be_false
}
