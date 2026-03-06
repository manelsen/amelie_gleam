// Core puro — recebe dados, devolve Acoes.
// Não executa nenhum efeito. Testável sem infraestrutura.

import core/comando/dispatcher
import core/prompt/builder
import core/validacao
import dominio/acao.{
  type Acao, EnfileirarMidia, EnviarTexto, NaoResponder, MidiaAudio,
  MidiaDocumento, MidiaImagem, MidiaVideo,
}
import dominio/config.{type Config}
import dominio/erro.{type Erro}
import dominio/mensagem.{
  type Mensagem, type Turno, Audio, Comando, Documento, Imagem, Texto, Video,
}
import gleam/result

pub fn processar(
  msg: Mensagem,
  config: Config,
  historico: List(Turno),
) -> Result(List(Acao), Erro) {
  use msg_val <- result.try(validacao.validar_mensagem(msg))

  case msg_val.corpo {
    Texto(body) -> processar_texto(body, config, historico)
    Comando(nome, args) -> processar_comando(nome, args, config)
    Imagem(..) -> processar_midia(msg_val, config, MidiaImagem)
    Audio(..) -> processar_midia(msg_val, config, MidiaAudio)
    Video(..) -> processar_midia(msg_val, config, MidiaVideo)
    Documento(..) -> processar_midia(msg_val, config, MidiaDocumento)
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
      let prompt = builder.montar(texto_val, config, historico)
      // Nota: a chamada à IA é efeito — o core retorna o prompt montado
      // e o shell chama a IA com ele.
      Ok([EnviarTexto(para: config.chat_id, corpo: prompt)])
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

  case ativa {
    False -> Ok([NaoResponder])
    True -> Ok([EnfileirarMidia(chat_id: msg.chat_id, tipo: tipo)])
  }
}
