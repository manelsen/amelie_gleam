// Monta prompts para a IA. Puro — sem efeitos.

import dominio/config.{type Config}
import dominio/mensagem.{type Turno, TurnoAssistente, TurnoUsuario}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string

pub fn montar(
  texto: String,
  config: Config,
  historico: List(Turno),
) -> String {
  let cabecalho = montar_cabecalho(config)
  let hist_str = montar_historico(historico, config.historico_max)

  [cabecalho, hist_str, "Usuário: " <> texto]
  |> list.filter(fn(s) { s != "" })
  |> string.join("\n\n")
}

fn montar_cabecalho(config: Config) -> String {
  case config.prompt_sistema {
    Some(prompt) -> prompt
    None -> prompt_padrao(config)
  }
}

fn prompt_padrao(config: Config) -> String {
  "Você é Amélie, uma assistente de IA no WhatsApp. "
  <> "Responda em "
  <> config.idioma
  <> ". "
  <> "Seja direta e útil."
}

fn montar_historico(turnos: List(Turno), max: Int) -> String {
  let total = list.length(turnos)
  turnos
  |> list.drop(int.max(0, total - max))
  |> list.map(formatar_turno)
  |> string.join("\n")
}

fn formatar_turno(turno: Turno) -> String {
  case turno {
    TurnoUsuario(c) -> "Usuário: " <> c
    TurnoAssistente(c) -> "Amélie: " <> c
  }
}

pub fn montar_para_imagem(config: Config) -> String {
  case config.prompt_sistema {
    Some(p) -> p <> "\n\nDescreva esta imagem de forma útil e acessível."
    None ->
      "Você é Amélie. Descreva esta imagem de forma útil e acessível, em "
      <> config.idioma
      <> "."
  }
}

pub fn montar_para_audio(config: Config) -> String {
  case config.prompt_sistema {
    Some(p) -> p <> "\n\nTranscreva e resuma este áudio."
    None ->
      "Você é Amélie. Transcreva e resuma este áudio em "
      <> config.idioma
      <> "."
  }
}

pub fn montar_para_video(config: Config) -> String {
  case config.prompt_sistema {
    Some(p) -> p <> "\n\nAnalise e resuma este vídeo."
    None ->
      "Você é Amélie. Analise e resuma este vídeo em "
      <> config.idioma
      <> "."
  }
}
