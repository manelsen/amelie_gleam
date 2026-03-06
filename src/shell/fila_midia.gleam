// Fila de mídia — executa processamento assíncrono de imagem, áudio, vídeo e documento.
// Shell: tem side effects (chama IA, envia mensagens).

import core/prompt/builder
import dominio/acao.{MidiaAudio, MidiaDocumento, MidiaImagem, MidiaVideo, type TipoMidia}
import dominio/config.{type Config}
import dominio/erro.{type Erro}
import dominio/mensagem.{type Mensagem, Audio, Documento, Imagem, Video}
import gleam/erlang/process.{type Subject}
import gleam/otp/actor
import gleam/result
import portas/ia_porta.{type IAPorta}
import portas/whatsapp_porta.{type WhatsappPorta}

pub type FilaMidia =
  Subject(MensagemFila)

pub type MensagemFila {
  Enfileirar(
    chat_id: String,
    msg: Mensagem,
    tipo: TipoMidia,
    cfg: Config,
    ia: IAPorta,
    whatsapp: WhatsappPorta,
  )
  Parar
}

// gleam_otp 1.x — builder pattern
pub fn iniciar() -> Result(FilaMidia, actor.StartError) {
  actor.new(Nil)
  |> actor.on_message(fn(state, msg) {
    case msg {
      Parar -> actor.stop()
      Enfileirar(chat_id, mensagem, tipo, cfg, ia, whatsapp) -> {
        let _ = processar(chat_id, mensagem, tipo, cfg, ia, whatsapp)
        actor.continue(state)
      }
    }
  })
  |> actor.start()
  |> result.map(fn(started) { started.data })
}

pub fn enfileirar(
  fila: FilaMidia,
  chat_id: String,
  msg: Mensagem,
  tipo: TipoMidia,
  cfg: Config,
  ia: IAPorta,
  whatsapp: WhatsappPorta,
) -> Result(Nil, Erro) {
  process.send(fila, Enfileirar(chat_id, msg, tipo, cfg, ia, whatsapp))
  Ok(Nil)
}

fn processar(
  chat_id: String,
  msg: Mensagem,
  tipo: TipoMidia,
  cfg: Config,
  ia: IAPorta,
  whatsapp: WhatsappPorta,
) -> Result(Nil, Erro) {
  case tipo {
    MidiaImagem -> processar_imagem(chat_id, msg, cfg, ia, whatsapp)
    MidiaAudio -> processar_audio(chat_id, msg, cfg, ia, whatsapp)
    MidiaVideo -> processar_video(chat_id, msg, cfg, ia, whatsapp)
    MidiaDocumento -> processar_documento(chat_id, msg, cfg, ia, whatsapp)
  }
}

fn processar_imagem(
  chat_id: String,
  msg: Mensagem,
  cfg: Config,
  ia: IAPorta,
  whatsapp: WhatsappPorta,
) -> Result(Nil, Erro) {
  case msg.corpo {
    Imagem(mime: mime, dados: dados) -> {
      let prompt = builder.montar_para_imagem(cfg)
      use resposta <- result.try(ia.processar_imagem(dados, mime, prompt, cfg.modelo))
      whatsapp.enviar(chat_id, resposta)
    }
    _ -> Ok(Nil)
  }
}

fn processar_audio(
  chat_id: String,
  msg: Mensagem,
  cfg: Config,
  ia: IAPorta,
  whatsapp: WhatsappPorta,
) -> Result(Nil, Erro) {
  case msg.corpo {
    Audio(mime: mime, dados: dados) -> {
      use resposta <- result.try(ia.processar_audio(dados, mime, cfg.modelo))
      whatsapp.enviar(chat_id, resposta)
    }
    _ -> Ok(Nil)
  }
}

fn processar_video(
  chat_id: String,
  msg: Mensagem,
  cfg: Config,
  ia: IAPorta,
  whatsapp: WhatsappPorta,
) -> Result(Nil, Erro) {
  case msg.corpo {
    Video(caminho_temp: caminho, mime: mime) -> {
      let prompt = builder.montar_para_video(cfg)
      use uri <- result.try(ia.fazer_upload_video(caminho, mime))
      use _ <- result.try(ia.aguardar_video_ativo(uri))
      use resposta <- result.try(ia.processar_video(uri, prompt, cfg.modelo))
      use _ <- result.try(ia.deletar_arquivo(uri))
      whatsapp.enviar(chat_id, resposta)
    }
    _ -> Ok(Nil)
  }
}

fn processar_documento(
  chat_id: String,
  msg: Mensagem,
  cfg: Config,
  ia: IAPorta,
  whatsapp: WhatsappPorta,
) -> Result(Nil, Erro) {
  case msg.corpo {
    Documento(mime: mime, dados: dados, nome: _nome) -> {
      let prompt = builder.montar_para_audio(cfg)
      use resposta <- result.try(
        ia.processar_documento(dados, mime, prompt, cfg.modelo),
      )
      whatsapp.enviar(chat_id, resposta)
    }
    _ -> Ok(Nil)
  }
}
