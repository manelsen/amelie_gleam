// Shell — executa os efeitos prescritos pelo core.
// Este módulo tem side effects: chama portas, grava histórico.

import core/processador
import dominio/acao.{EnfileirarMidia, EnviarReacao, EnviarTexto, NaoResponder}
import dominio/config
import dominio/erro.{type Erro}
import dominio/mensagem.{
  type Mensagem, type Turno, Audio, Documento, Imagem, TurnoAssistente,
  TurnoUsuario, Texto, Video,
}
import gleam/list
import gleam/result
import portas/config_porta.{type ConfigPorta}
import portas/historico_porta.{type HistoricoPorta}
import portas/ia_porta.{type IAPorta}
import portas/whatsapp_porta.{type WhatsappPorta}
import shell/fila_midia.{type FilaMidia}

pub type Portas {
  Portas(
    whatsapp: WhatsappPorta,
    ia: IAPorta,
    config: ConfigPorta,
    historico: HistoricoPorta,
    fila: FilaMidia,
  )
}

pub fn handle(msg: Mensagem, portas: Portas) -> Result(Nil, Erro) {
  use cfg <- result.try(portas.config.obter(msg.chat_id))
  use hist <- result.try(portas.historico.obter(msg.chat_id))
  use acoes <- result.try(processador.processar(msg, cfg, hist))

  acoes
  |> list.map(executar_acao(_, msg, cfg, hist, portas))
  |> result.all
  |> result.map(fn(_) { Nil })
}

fn executar_acao(
  acao: acao.Acao,
  msg: Mensagem,
  cfg: config.Config,
  hist: List(Turno),
  portas: Portas,
) -> Result(Nil, Erro) {
  case acao {
    // O core montou o prompt no corpo de EnviarTexto — o shell chama a IA.
    EnviarTexto(para, prompt) -> {
      use resposta <- result.try(
        portas.ia.gerar_texto(prompt, hist, cfg.modelo),
      )
      use _ <- result.try(portas.whatsapp.enviar(para, resposta))
      use _ <- result.try(
        portas.historico.adicionar(
          msg.chat_id,
          TurnoUsuario(extrair_texto_usuario(msg)),
        ),
      )
      portas.historico.adicionar(msg.chat_id, TurnoAssistente(resposta))
    }

    EnviarReacao(para, emoji) ->
      portas.whatsapp.enviar(para, emoji)

    EnfileirarMidia(chat_id, tipo) ->
      fila_midia.enfileirar(portas.fila, chat_id, msg, tipo, cfg, portas.ia, portas.whatsapp)

    NaoResponder -> Ok(Nil)
  }
}

fn extrair_texto_usuario(msg: Mensagem) -> String {
  case msg.corpo {
    Texto(body) -> body
    Imagem(..) -> "[imagem]"
    Audio(..) -> "[áudio]"
    Video(..) -> "[vídeo]"
    Documento(nome: nome, ..) -> "[documento: " <> nome <> "]"
    mensagem.Comando(nome, args) -> "." <> nome <> " " <> args
  }
}
