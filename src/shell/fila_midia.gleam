// Fila de mídia — executa processamento assíncrono de imagem, áudio, vídeo e documento.
// Shell: tem side effects (chama IA, envia mensagens).

import core/acessibilidade
import core/prompt/builder
import dominio/acao.{
  type TipoMidia, MidiaAudio, MidiaDocumento, MidiaImagem, MidiaSticker,
  MidiaVideo,
}
import dominio/config.{type Config}
import dominio/erro.{type Erro}
import dominio/mensagem.{type Mensagem, Audio, Documento, Imagem, Video}
import gleam/erlang/process.{type Subject}
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision
import gleam/result
import gleam/string
import logging
import portas/ia_porta.{type IAPorta}
import portas/mensageiro_porta.{type MensageiroPorta}
import portas/transacao_porta.{type TransacaoPorta}
import shell/entrega_auditada
import simplifile

pub type FilaMidia =
  Subject(MensagemFila)

pub type FilasMidia {
  FilasMidia(
    imagem: FilaMidia,
    audio: FilaMidia,
    video: FilaMidia,
    documento: FilaMidia,
    sticker: FilaMidia,
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

pub fn iniciar_uma_actor(
  name: Option(process.Name(MensagemFila)),
) -> Result(actor.Started(FilaMidia), actor.StartError) {
  let builder =
    actor.new(Nil)
    |> actor.on_message(fn(state, msg) {
      case msg {
        Parar -> actor.stop()
        Enfileirar(chat_id, mensagem, tipo, cfg, ia, mensageiro, transacoes) -> {
          case
            processar(chat_id, mensagem, tipo, cfg, ia, mensageiro, transacoes)
          {
            Ok(_) -> Nil
            Error(e) ->
              logging.log(
                logging.Warning,
                "Erro ao processar mídia em "
                  <> chat_id
                  <> ": "
                  <> erro.descricao(e),
              )
          }
          actor.continue(state)
        }
      }
    })

  let builder = case name {
    Some(n) -> actor.named(builder, n)
    None -> builder
  }

  actor.start(builder)
}

pub fn supervisionado_um(
  name: process.Name(MensagemFila),
) -> supervision.ChildSpecification(FilaMidia) {
  supervision.worker(fn() { iniciar_uma_actor(Some(name)) })
}

fn iniciar_uma() -> Result(FilaMidia, actor.StartError) {
  iniciar_uma_actor(None)
  |> result.map(fn(started) { started.data })
}

pub fn iniciar_todas() -> Result(FilasMidia, actor.StartError) {
  use img <- result.try(iniciar_uma())
  use aud <- result.try(iniciar_uma())
  use vid <- result.try(iniciar_uma())
  use doc <- result.try(iniciar_uma())
  use stk <- result.try(iniciar_uma())
  Ok(FilasMidia(
    imagem: img,
    audio: aud,
    video: vid,
    documento: doc,
    sticker: stk,
  ))
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
    MidiaSticker -> filas.sticker
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
    MidiaImagem ->
      processar_imagem(chat_id, msg, cfg, ia, mensageiro, transacoes)
    MidiaAudio -> processar_audio(chat_id, msg, cfg, ia, mensageiro, transacoes)
    MidiaVideo -> processar_video(chat_id, msg, cfg, ia, mensageiro, transacoes)
    MidiaDocumento ->
      processar_documento(chat_id, msg, cfg, ia, mensageiro, transacoes)
    MidiaSticker ->
      processar_sticker(chat_id, msg, cfg, ia, mensageiro, transacoes)
  }
}

fn tag_trace(msg: Mensagem) -> String {
  case msg.message_id {
    option.Some(id) if id != "" -> " [trace:" <> id <> "]"
    _ -> ""
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
      logging.log(
        logging.Info,
        "[Imagem]"
          <> tag_trace(msg)
          <> " Iniciando processamento para "
          <> chat_id,
      )
      reagir(msg, "⌛", mensageiro)
      let prompt = builder.montar_para_imagem(cfg, msg.legenda)
      use resposta <- result.try(ia.processar_imagem(
        dados,
        mime,
        prompt,
        cfg.modelo,
      ))
      logging.log(
        logging.Info,
        "[Imagem]" <> tag_trace(msg) <> " Concluído para " <> chat_id,
      )
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
      logging.log(
        logging.Info,
        "[Áudio]"
          <> tag_trace(msg)
          <> " Iniciando processamento para "
          <> chat_id,
      )
      reagir(msg, "⌛", mensageiro)
      let prompt = builder.montar_para_audio(cfg)
      use resposta <- result.try(ia.processar_audio(
        dados,
        mime,
        prompt,
        cfg.modelo,
      ))
      let resposta = limpar_timestamps(resposta)
      logging.log(
        logging.Info,
        "[Áudio]" <> tag_trace(msg) <> " Concluído para " <> chat_id,
      )
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
      logging.log(
        logging.Info,
        "[Vídeo]"
          <> tag_trace(msg)
          <> " Iniciando upload e processamento para "
          <> chat_id,
      )
      reagir(msg, "⌛", mensageiro)
      let eh_sticker_animado =
        msg.legenda
        |> option.unwrap("")
        |> string.contains("figurinha/sticker")
      let tem_audio = video_tem_audio(caminho)
      let prompt = case eh_sticker_animado {
        True -> builder.montar_para_sticker_animado(cfg, msg.legenda)
        False ->
          case cfg.legenda_ativo && tem_audio {
            True -> builder.montar_para_legenda(cfg)
            False ->
              builder.montar_para_video_com_audio(cfg, msg.legenda, tem_audio)
          }
      }
      case ia.fazer_upload_video(caminho, mime) {
        Error(e) -> {
          let _ = simplifile.delete_file(caminho)
          Error(e)
        }
        Ok(uri) -> {
          let processamento = {
            use _ <- result.try(ia.aguardar_video_ativo(uri))
            use resposta <- result.try(ia.processar_video(
              uri,
              prompt,
              cfg.modelo,
            ))
            Ok(resposta)
          }
          let _ = ia.deletar_arquivo(uri)
          let _ = simplifile.delete_file(caminho)
          use resposta <- result.try(processamento)
          logging.log(
            logging.Info,
            "[Vídeo]" <> tag_trace(msg) <> " Concluído para " <> chat_id,
          )
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
      logging.log(
        logging.Info,
        "[Doc]" <> tag_trace(msg) <> " Iniciando processamento para " <> chat_id,
      )
      reagir(msg, "⌛", mensageiro)
      let prompt = builder.montar_para_documento(cfg, msg.legenda)
      use resposta <- result.try(ia.processar_documento(
        dados,
        mime,
        prompt,
        cfg.modelo,
      ))
      logging.log(
        logging.Info,
        "[Doc]" <> tag_trace(msg) <> " Concluído para " <> chat_id,
      )
      reagir(msg, "🆗", mensageiro)
      entregar(chat_id, "documento", resposta, msg, mensageiro, transacoes)
    }
    _ -> Ok(Nil)
  }
}

fn processar_sticker(
  chat_id: String,
  msg: Mensagem,
  cfg: Config,
  ia: IAPorta,
  mensageiro: MensageiroPorta,
  transacoes: TransacaoPorta,
) -> Result(Nil, Erro) {
  case msg.corpo {
    mensagem.Sticker(mime: mime, dados: dados) -> {
      logging.log(
        logging.Info,
        "[Sticker]"
          <> tag_trace(msg)
          <> " Iniciando processamento para "
          <> chat_id,
      )
      reagir(msg, "⌛", mensageiro)
      let prompt = builder.montar_para_sticker(cfg, msg.legenda)
      // Stickers são tratados como imagens para a IA
      use resposta <- result.try(ia.processar_imagem(
        dados,
        mime,
        prompt,
        cfg.modelo,
      ))
      logging.log(
        logging.Info,
        "[Sticker]" <> tag_trace(msg) <> " Concluído para " <> chat_id,
      )
      reagir(msg, "🆗", mensageiro)
      entregar(chat_id, "sticker", resposta, msg, mensageiro, transacoes)
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
  let resposta_sanitizada = acessibilidade.sanitizar_saida_voz(resposta)
  case msg.message_id {
    option.Some(mid) ->
      entrega_auditada.enviar_citando(
        chat_id,
        "amelie",
        tipo,
        resposta_sanitizada,
        mid,
        msg.remetente,
        mensageiro,
        transacoes,
      )
    option.None ->
      entrega_auditada.enviar(
        chat_id,
        "amelie",
        tipo,
        resposta_sanitizada,
        mensageiro,
        transacoes,
      )
  }
}

// Remove timestamps (MM:SS ou HH:MM:SS) que o Gemini insiste em gerar,
// e colapsa linhas vazias resultantes.
fn limpar_timestamps(texto: String) -> String {
  let limpo = strip_timestamps_ffi(texto)
  // Colapsa múltiplas quebras de linha em no máximo duas (separador de parágrafo)
  colapsar_linhas_vazias(limpo)
}

fn colapsar_linhas_vazias(texto: String) -> String {
  case string.contains(texto, "\n\n\n") {
    True -> colapsar_linhas_vazias(string.replace(texto, "\n\n\n", "\n\n"))
    False -> string.trim(texto)
  }
}

@external(erlang, "amelie_gleam_ffi", "strip_timestamps")
fn strip_timestamps_ffi(texto: String) -> String

@external(erlang, "amelie_gleam_ffi", "video_tem_audio")
fn video_tem_audio(caminho: String) -> Bool
