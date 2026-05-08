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
  <> "Seja direta e útil. "
  <> "Você consegue processar e descrever imagens, áudios, vídeos e documentos enviados diretamente na conversa."
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

fn sem_introducao() -> String {
  "\nNão use introduções conversacionais como \"Olá! Sou Amélie\" ou \"Estou aqui para ajudar\". Vá direto ao conteúdo."
}

pub fn montar_para_imagem(config: Config, legenda: Option(String)) -> String {
  let contexto = case config.prompt_sistema {
    Some(p) -> p <> "\n\n"
    None -> ""
  }
  contexto
  <> "Faça a audiodescrição desta imagem em "
  <> config.idioma
  <> ". REGRAS:"
  <> "\n- Comece identificando o tipo de imagem (fotografia, ilustração, gráfico, mapa, captura de tela, etc.)."
  <> "\n- Descreva do geral ao específico: contexto geral primeiro, depois detalhes."
  <> "\n- Inclua: cores, posições espaciais, textos visíveis (transcreva-os na íntegra), expressões faciais, ações e cenário."
  <> "\n- Identifique pessoas por nome (se reconhecíveis) ou por atributo físico visível."
  <> "\n- Seja objetiva: descreva apenas o que é visível, sem interpretar intenções ou estados mentais. Não censure conteúdo."
  <> "\n- Use tempo presente, voz ativa e terceira pessoa."
  <> "\n- Linguagem clara e precisa."
  <> sufixo_modo(config)
  <> sufixo_legenda(legenda)
  <> sem_introducao()
  <> "\nInicie sua resposta exatamente com \"Audiodescrição da imagem\" e finalize com \"Fim da audiodescrição\"."
}

pub fn montar_para_audio(config: Config) -> String {
  let contexto = case config.prompt_sistema {
    Some(p) -> p <> "\n\n"
    None -> ""
  }
  contexto
  <> "Transcreva este áudio em "
  <> config.idioma
  <> ". REGRAS OBRIGATÓRIAS:"
  <> "\n1. Produza SOMENTE a transcrição literal do que foi dito."
  <> "\n2. Use pontuação correta (vírgulas, pontos, interrogações, exclamações) para refletir a fala."
  <> "\n3. Separe em parágrafos por mudança de assunto ou pausa longa."
  <> "\n4. NÃO inclua resumo, análise, comentários, descrições do áudio ou formatação markdown."
  <> "\n5. NÃO inclua timestamps."
  <> "\n6. NÃO cumprimente ou se apresente."
  <> "\n7. Inicie a resposta exatamente com \"Transcrição do áudio\" seguido de quebra de linha."
  <> "\n8. Finalize exatamente com \"Fim da transcrição\"."
}

pub fn montar_para_video(config: Config, legenda: Option(String)) -> String {
  let contexto = case config.prompt_sistema {
    Some(p) -> p <> "\n\n"
    None -> ""
  }
  contexto
  <> "Faça a audiodescrição deste vídeo em "
  <> config.idioma
  <> ". REGRAS:"
  <> "\n- Descreva ações, personagens, cenários e mudanças de cena em sequência cronológica."
  <> "\n- Inclua: cores, posições espaciais, expressões faciais, gestos, vestuário e ambiente."
  <> "\n- Incorpore o que é dito ou narrado no áudio, integrando fala e descrição visual."
  <> "\n- Transcreva na íntegra qualquer texto visível na tela (títulos, legendas, créditos, placas)."
  <> "\n- Identifique a origem de sons não óbvios quando relevante."
  <> "\n- Identifique pessoas por nome (se reconhecíveis) ou por atributo físico visível."
  <> "\n- Seja objetiva: descreva apenas o observável, sem interpretar intenções ou estados mentais. Não censure conteúdo."
  <> "\n- Use tempo presente, voz ativa e terceira pessoa."
  <> "\n- Linguagem clara e precisa. Não inclua timestamps."
  <> sufixo_modo(config)
  <> sufixo_legenda(legenda)
  <> sem_introducao()
  <> "\nInicie sua resposta exatamente com \"Audiodescrição do vídeo\" e finalize com \"Fim da audiodescrição\"."
}

pub fn montar_para_legenda(config: Config) -> String {
  let contexto = case config.prompt_sistema {
    Some(p) -> p <> "\n\n"
    None -> ""
  }
  contexto
  <> "Transcreva a trilha de áudio deste vídeo em "
  <> config.idioma
  <> ", gerando legendas acessíveis para pessoas surdas ou com deficiência auditiva."
  <> "\n- Identifique os falantes quando houver mais de um."
  <> "\n- Descreva sons relevantes entre colchetes (ex: [aplausos], [música de fundo])."
  <> "\n- Transcreva textos visíveis na tela que complementem o áudio."
  <> sem_introducao()
  <> "\nInicie sua resposta exatamente com \"Transcrição do vídeo\" e finalize com \"Fim da transcrição\"."
}

pub fn montar_para_documento(
  config: Config,
  legenda: Option(String),
) -> String {
  let base = case config.prompt_sistema {
    Some(p) -> p <> "\n\nAnalise e resuma este documento."
    None ->
      "Analise e resuma este documento em "
      <> config.idioma
      <> "."
  }
  base
  <> sufixo_modo(config)
  <> sufixo_legenda(legenda)
  <> sem_introducao()
  <> "\nInicie sua resposta exatamente com \"Descrição do documento\" e finalize com \"Fim da descrição\"."
}

