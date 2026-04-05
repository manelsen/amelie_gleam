// Fila de mídia — executa processamento assíncrono de imagem, áudio, vídeo e documento.
// Shell: tem side effects (chama IA, envia mensagens).

import core/prompt/builder
import dominio/acao.{MidiaAudio, MidiaDocumento, MidiaImagem, MidiaVideo, type TipoMidia}
import dominio/config.{type Config}
import dominio/erro.{type Erro}
import dominio/mensagem.{type Mensagem, Audio, Documento, Imagem, Video}
import gleam/erlang/process.{type Subject}
import gleam/option
import gleam/otp/actor
import gleam/result
import logging
import portas/ia_porta.{type IAPorta}
import portas/transacao_porta.{type TransacaoPorta}
import portas/mensageiro_porta.{type MensageiroPorta}
import shell/entrega_auditada

pub type FilaMidia =
  Subject(MensagemFila)

pub type FilasMidia {
  FilasMidia(
    imagem: FilaMidia,
    audio: FilaMidia,
    video: FilaMidia,
    documento: FilaMidia,
  )
}

pub type MensagemFila {
  Enfileirar(
    chat_id: String,
    msg: Mensagem,
    tipo: TipoMidia,
    cfg: Config,
    ia: IAPorta,
    mensageiro: MensageiroPorta,
    transacoes: TransacaoPorta,
  )
  Parar
}

fn iniciar_uma() -> Result(FilaMidia, actor.StartError) {
  actor.new(Nil)
  |> actor.on_message(fn(state, msg) {
    case msg {
      Parar -> actor.stop()
      Enfileirar(chat_id, mensagem, tipo, cfg, ia, mensageiro, transacoes) -> {
        case processar(chat_id, mensagem, tipo, cfg, ia, mensageiro, transacoes) {
          Ok(_) -> Nil
          Error(e) ->
            logging.log(
              logging.Warning,
              "Erro ao processar mídia em " <> chat_id <> ": " <> erro.descricao(e),
            )
        }
        actor.continue(state)
      }
    }
  })
  |> actor.start()
  |> result.map(fn(started) { started.data })
}

pub fn iniciar_todas() -> Result(FilasMidia, actor.StartError) {
  use img <- result.try(iniciar_uma())
  use aud <- result.try(iniciar_uma())
  use vid <- result.try(iniciar_uma())
  use doc <- result.try(iniciar_uma())
  Ok(FilasMidia(imagem: img, audio: aud, video: vid, documento: doc))
}

pub fn enfileirar(
  filas: FilasMidia,
  chat_id: String,
  msg: Mensagem,
  tipo: TipoMidia,
  cfg: Config,
  ia: IAPorta,
  mensageiro: MensageiroPorta,
  transacoes: TransacaoPorta,
) -> Result(Nil, Erro) {
  let fila = case tipo {
    MidiaImagem -> filas.imagem
    MidiaAudio -> filas.audio
    MidiaVideo -> filas.video
    MidiaDocumento -> filas.documento
  }
  process.send(
    fila,
    Enfileirar(chat_id, msg, tipo, cfg, ia, mensageiro, transacoes),
  )
  Ok(Nil)
}

fn processar(
  chat_id: String,
  msg: Mensagem,
  tipo: TipoMidia,
  cfg: Config,
  ia: IAPorta,
  mensageiro: MensageiroPorta,
  transacoes: TransacaoPorta,
) -> Result(Nil, Erro) {
  case tipo {
    MidiaImagem -> processar_imagem(chat_id, msg, cfg, ia, mensageiro, transacoes)
    MidiaAudio -> processar_audio(chat_id, msg, cfg, ia, mensageiro, transacoes)
    MidiaVideo -> processar_video(chat_id, msg, cfg, ia, mensageiro, transacoes)
    MidiaDocumento ->
      processar_documento(chat_id, msg, cfg, ia, mensageiro, transacoes)
  }
}

fn processar_imagem(
  chat_id: String,
  msg: Mensagem,
  cfg: Config,
  ia: IAPorta,
  mensageiro: MensageiroPorta,
  transacoes: TransacaoPorta,
) -> Result(Nil, Erro) {
  case msg.corpo {
    Imagem(mime: mime, dados: dados) -> {
      logging.log(logging.Info, "[Imagem] Iniciando processamento para " <> chat_id)
      reagir(msg, "⌛", mensageiro)
      let prompt = builder.montar_para_imagem(cfg, msg.legenda)
      use resposta <- result.try(ia.processar_imagem(dados, mime, prompt, cfg.modelo))
      logging.log(logging.Info, "[Imagem] Concluído para " <> chat_id)
      reagir(msg, "🆗", mensageiro)
      entregar(chat_id, "imagem", resposta, msg, mensageiro, transacoes)
    }
    _ -> Ok(Nil)
  }
}

fn processar_audio(
  chat_id: String,
  msg: Mensagem,
  cfg: Config,
  ia: IAPorta,
  mensageiro: MensageiroPorta,
  transacoes: TransacaoPorta,
) -> Result(Nil, Erro) {
  case msg.corpo {
    Audio(mime: mime, dados: dados) -> {
      logging.log(logging.Info, "[Áudio] Iniciando processamento para " <> chat_id)
      reagir(msg, "⌛", mensageiro)
      use resposta <- result.try(ia.processar_audio(dados, mime, cfg.modelo))
      logging.log(logging.Info, "[Áudio] Concluído para " <> chat_id)
      reagir(msg, "🆗", mensageiro)
      entregar(chat_id, "audio", resposta, msg, mensageiro, transacoes)
    }
    _ -> Ok(Nil)
  }
}

fn processar_video(
  chat_id: String,
  msg: Mensagem,
  cfg: Config,
  ia: IAPorta,
  mensageiro: MensageiroPorta,
  transacoes: TransacaoPorta,
) -> Result(Nil, Erro) {
  case msg.corpo {
    Video(caminho_temp: caminho, mime: mime) -> {
      logging.log(logging.Info, "[Vídeo] Iniciando upload e processamento para " <> chat_id)
      reagir(msg, "⌛", mensageiro)
      let prompt = case cfg.legenda_ativo {
        True -> builder.montar_para_legenda(cfg)
        False -> builder.montar_para_video(cfg, msg.legenda)
      }
      case ia.fazer_upload_video(caminho, mime) {
        Error(e) -> {
          let _ = simplifile_delete(caminho)
          Error(e)
        }
        Ok(uri) -> {
          let processamento = {
            use _ <- result.try(ia.aguardar_video_ativo(uri))
            use resposta <- result.try(ia.processar_video(uri, prompt, cfg.modelo))
            Ok(resposta)
          }
          let _ = ia.deletar_arquivo(uri)
          let _ = simplifile_delete(caminho)
          use resposta <- result.try(processamento)
          logging.log(logging.Info, "[Vídeo] Concluído para " <> chat_id)
          reagir(msg, "🆗", mensageiro)
          entregar(chat_id, "video", resposta, msg, mensageiro, transacoes)
        }
      }
    }
    _ -> Ok(Nil)
  }
}

fn processar_documento(
  chat_id: String,
  msg: Mensagem,
  cfg: Config,
  ia: IAPorta,
  mensageiro: MensageiroPorta,
  transacoes: TransacaoPorta,
) -> Result(Nil, Erro) {
  case msg.corpo {
    Documento(mime: mime, dados: dados, nome: _nome) -> {
      logging.log(logging.Info, "[Doc] Iniciando processamento para " <> chat_id)
      reagir(msg, "⌛", mensageiro)
      let prompt = builder.montar_para_documento(cfg, msg.legenda)
      use resposta <- result.try(
        ia.processar_documento(dados, mime, prompt, cfg.modelo),
      )
      logging.log(logging.Info, "[Doc] Concluído para " <> chat_id)
      reagir(msg, "🆗", mensageiro)
      entregar(chat_id, "documento", resposta, msg, mensageiro, transacoes)
    }
    _ -> Ok(Nil)
  }
}

// Reage à mensagem original. Fire-and-forget — ignora falha.
fn reagir(msg: Mensagem, emoji: String, mensageiro: MensageiroPorta) -> Nil {
  case msg.message_id {
    option.Some(mid) -> {
      let _ = mensageiro.reagir(msg.chat_id, mid, msg.remetente, emoji)
      Nil
    }
    option.None -> Nil
  }
}

// Entrega citando a mensagem original quando possível.
fn entregar(
  chat_id: String,
  tipo: String,
  resposta: String,
  msg: Mensagem,
  mensageiro: MensageiroPorta,
  transacoes: TransacaoPorta,
) -> Result(Nil, Erro) {
  case msg.message_id {
    option.Some(mid) ->
      entrega_auditada.enviar_citando(
        chat_id,
        "amelie",
        tipo,
        resposta,
        mid,
        msg.remetente,
        mensageiro,
        transacoes,
      )
    option.None ->
      entrega_auditada.enviar(chat_id, "amelie", tipo, resposta, mensageiro, transacoes)
  }
}

@external(erlang, "file", "delete")
fn simplifile_delete(path: String) -> Result(Nil, ErlFileError)

type ErlFileError
