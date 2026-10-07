// Core puro — recebe dados, devolve Acoes.
// Não executa nenhum efeito. Testável sem infraestrutura.

import core/comando/dispatcher
import core/prompt/builder
import core/validacao
import dominio/acao.{
  type Acao, BaixarVideoUrlEDescrever, BuscarUrlEResponder, EnfileirarMidia,
  EnviarResposta, GerarEEnviar, MidiaAudio, MidiaDocumento, MidiaImagem,
  MidiaVideo, NaoResponder,
}
import dominio/config.{type Config}
import dominio/erro.{type Erro}
import dominio/mensagem.{
  type Mensagem, type Turno, Audio, Comando, Documento, Imagem, Texto, Video,
}
import gleam/bool
import gleam/list
import gleam/option
import gleam/result
import gleam/string

pub fn processar(
  msg: Mensagem,
  config: Config,
  historico: List(Turno),
) -> Result(List(Acao), Erro) {
  use msg_val <- result.try(validacao.validar_mensagem(msg))

  // Ignora mensagens do próprio bot (previne loops)
  use <- bool.guard(validacao.e_mensagem_propria(msg_val), Ok([NaoResponder]))

  processar_filtrado(msg_val, config, historico)
}

fn processar_filtrado(
  msg: Mensagem,
  config: Config,
  historico: List(Turno),
) -> Result(List(Acao), Erro) {
  // Em grupos, ignora mensagens que não mencionam o bot (exceto comandos)
  use <- bool.guard(
    msg.em_grupo && !msg.menciona_bot && !mensagem.e_comando(msg),
    Ok([NaoResponder]),
  )

  case msg.corpo {
    Texto(body) -> processar_texto(body, config, historico)
    Comando(nome, args) -> processar_comando(nome, args, config)
    Imagem(..) -> processar_midia(msg, config, MidiaImagem)
    Audio(..) -> processar_midia(msg, config, MidiaAudio)
    Video(..) -> processar_midia(msg, config, MidiaVideo)
    Documento(..) -> processar_midia(msg, config, MidiaDocumento)
    mensagem.MidiaIndisponivel(mensagem) ->
      Ok([EnviarResposta(config.chat_id, mensagem)])
  }
}

fn processar_texto(
  body: String,
  config: Config,
  historico: List(Turno),
) -> Result(List(Acao), Erro) {
  // Verificar se é comando camuflado como texto (começa com ".")
  case validacao.parsear_comando(body) {
    Ok(#(nome, args)) -> processar_comando(nome, args, config)
    Error(_) -> {
      use texto_val <- result.try(validacao.validar_texto(body))
      case extrair_url(texto_val) {
        option.Some(url) ->
          case e_url_video(url) && config.video_ativo {
            True ->
              Ok([BaixarVideoUrlEDescrever(chat_id: config.chat_id, url: url)])
            False ->
              Ok([
                BuscarUrlEResponder(
                  para: config.chat_id,
                  texto: texto_val,
                  url: url,
                ),
              ])
          }
        option.None -> {
          let prompt = builder.montar(texto_val, config, historico)
          Ok([GerarEEnviar(para: config.chat_id, prompt: prompt)])
        }
      }
    }
  }
}

fn e_url_video(url: String) -> Bool {
  let url = string.lowercase(url)
  string.contains(url, "tiktok.com/")
  || string.contains(url, "vm.tiktok.com/")
  || string.contains(url, "instagram.com/reel")
  || string.contains(url, "instagram.com/reels/")
  || string.contains(url, "instagram.com/p/")
  || string.contains(url, "instagram.com/tv/")
  || string.contains(url, "instagram.com/stories/")
  || string.contains(url, "youtube.com/shorts/")
  || string.contains(url, "youtube.com/live/")
  || string.contains(url, "youtube.com/embed/")
  || string.contains(url, "youtube.com/watch")
  || string.contains(url, "m.youtube.com/watch")
  || string.contains(url, "music.youtube.com/watch")
  || string.contains(url, "youtu.be/")
}

fn extrair_url(texto: String) -> option.Option(String) {
  texto
  |> dividir_em_palavras()
  |> list.find(fn(palavra) {
    string.starts_with(palavra, "https://")
    || string.starts_with(palavra, "http://")
  })
  |> result.map(limpar_url)
  |> option.from_result
}

fn dividir_em_palavras(texto: String) -> List(String) {
  dividir_graphemes(string.to_graphemes(texto), [], [])
}

fn dividir_graphemes(
  restantes: List(String),
  palavra_atual: List(String),
  palavras: List(String),
) -> List(String) {
  case restantes {
    [] -> finalizar_palavra(palavra_atual, palavras) |> list.reverse
    [grapheme, ..resto] ->
      case string.trim(grapheme) == "" {
        True ->
          dividir_graphemes(
            resto,
            [],
            finalizar_palavra(palavra_atual, palavras),
          )
        False -> dividir_graphemes(resto, [grapheme, ..palavra_atual], palavras)
      }
  }
}

fn finalizar_palavra(
  palavra_atual: List(String),
  palavras: List(String),
) -> List(String) {
  case palavra_atual {
    [] -> palavras
    _ -> [palavra_atual |> list.reverse |> string.concat, ..palavras]
  }
}

fn limpar_url(url: String) -> String {
  url
  |> remover_prefixo("<")
  |> remover_prefixo("(")
  |> remover_sufixos([">", ")", "]", "}", ".", ",", ";", "!", "?", "\"", "'"])
}

fn remover_prefixo(texto: String, prefixo: String) -> String {
  case string.starts_with(texto, prefixo) {
    True -> string.drop_start(texto, string.length(prefixo))
    False -> texto
  }
}

fn remover_sufixos(texto: String, sufixos: List(String)) -> String {
  case sufixos {
    [] -> texto
    [sufixo, ..resto] -> {
      let sem_sufixo = case string.ends_with(texto, sufixo) {
        True -> string.drop_end(texto, string.length(sufixo))
        False -> texto
      }
      remover_sufixos(sem_sufixo, resto)
    }
  }
}

fn processar_comando(
  nome: String,
  args: String,
  config: Config,
) -> Result(List(Acao), Erro) {
  dispatcher.executar(nome, args, config)
}

fn processar_midia(
  msg: Mensagem,
  config: Config,
  tipo: acao.TipoMidia,
) -> Result(List(Acao), Erro) {
  let ativa = case tipo {
    MidiaImagem -> config.imagem_ativo
    MidiaAudio -> config.audio_ativo
    MidiaVideo -> config.video_ativo
    MidiaDocumento -> config.doc_ativo
  }

  use <- bool.guard(!ativa, Ok([NaoResponder]))
  Ok([EnfileirarMidia(chat_id: msg.chat_id, tipo: tipo)])
}
