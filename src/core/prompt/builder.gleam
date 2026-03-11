// Monta prompts para a IA. Puro — sem efeitos.

import dominio/config.{type Config, Curto, Longo, Normal}
import dominio/mensagem.{type Turno, TurnoAssistente, TurnoUsuario}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
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

pub fn montar_com_url(
  texto: String,
  url: String,
  conteudo_url: String,
  config: Config,
  historico: List(Turno),
) -> String {
  let base = montar(texto, config, historico)
  let ctx =
    "\n\n--- [Conteúdo lido da URL: "
    <> url
    <> "] ---\n"
    <> conteudo_url
    <> "\n--- [Fim do conteúdo] ---\n"
    <> "Use este conteúdo se o usuário pedir resumo ou informações sobre o link."
  base <> ctx
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

// ---------------------------------------------------------------------------
// Prompts de mídia — consideram modo_descricao e legenda opcional (caption)
// ---------------------------------------------------------------------------

fn sufixo_modo(config: Config) -> String {
  case config.modo_descricao {
    Longo ->
      " Forneça uma descrição completa e detalhada, incluindo todos os elementos visíveis, cores, textos, posições e contexto."
    Curto -> " Seja concisa e objetiva na descrição."
    Normal -> ""
  }
}

fn sufixo_legenda(legenda: Option(String)) -> String {
  case legenda {
    Some(caption) -> "\n\nO usuário pediu foco em: " <> caption
    None -> ""
  }
}

pub fn montar_para_imagem(config: Config, legenda: Option(String)) -> String {
  let base = case config.prompt_sistema {
    Some(p) -> p <> "\n\nDescreva esta imagem de forma útil e acessível."
    None ->
      "Você é Amélie. Descreva esta imagem de forma útil e acessível, em "
      <> config.idioma
      <> "."
  }
  base <> sufixo_modo(config) <> sufixo_legenda(legenda)
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

pub fn montar_para_video(config: Config, legenda: Option(String)) -> String {
  let base = case config.prompt_sistema {
    Some(p) -> p <> "\n\nAnalise e resuma este vídeo."
    None ->
      "Você é Amélie. Analise e resuma este vídeo em "
      <> config.idioma
      <> "."
  }
  base <> sufixo_modo(config) <> sufixo_legenda(legenda)
}

pub fn montar_para_legenda(config: Config) -> String {
  case config.prompt_sistema {
    Some(p) ->
      p
      <> "\n\nTranscreva a trilha de áudio deste vídeo, gerando legendas acessíveis."
    None ->
      "Você é Amélie. Transcreva a trilha de áudio deste vídeo em "
      <> config.idioma
      <> ", gerando legendas acessíveis para pessoas surdas ou com deficiência auditiva."
  }
}

pub fn montar_para_documento(
  config: Config,
  legenda: Option(String),
) -> String {
  let base = case config.prompt_sistema {
    Some(p) -> p <> "\n\nAnalise e resuma este documento."
    None ->
      "Você é Amélie. Analise e resuma este documento em "
      <> config.idioma
      <> "."
  }
  base <> sufixo_modo(config) <> sufixo_legenda(legenda)
}

