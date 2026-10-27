// shell/receptor_telegram.gleam
// Poller assíncrono de updates do Telegram (long polling via OTP / BEAM).
// Permite recepção de mensagens sem depender de webhook ou IP público.
// Toda chamada à Bot API passa pela TelegramPorta.

import dominio/id_chat.{type IdChat}
import dominio/mensagem.{type Conteudo, type Mensagem, Mensagem}
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import logging
import portas/telegram_porta.{
  type AcaoChat, type TelegramPorta, FalhaPolling, NovosUpdates, OutraInstancia,
  WebhookAtivo,
}
import shell/arquivos_temporarios
import shell/sistema
import shell/tratador_mensagem.{type Portas}

pub fn iniciar(api: TelegramPorta, portas: Portas) -> Nil {
  logging.log(logging.Info, "Iniciando Telegram poller (long polling)...")
  sistema.disparar(fn() { loop(api, 0, portas) })
}

fn loop(api: TelegramPorta, offset: Int, portas: Portas) -> Nil {
  case api.obter_updates(offset) {
    NovosUpdates(updates) -> {
      case updates {
        [] -> Nil
        _ ->
          logging.log(
            logging.Info,
            "Telegram poller recebeu "
              <> int.to_string(list.length(updates))
              <> " updates",
          )
      }
      loop(api, processar_updates(updates, offset, api, portas), portas)
    }
    WebhookAtivo ->
      logging.log(
        logging.Info,
        "Telegram poller: webhook ativo, polling desativado.",
      )
    OutraInstancia -> {
      logging.log(
        logging.Warning,
        "Telegram poller: conflito 409 (outra instância ativa). Aguardando 5s...",
      )
      process.sleep(5000)
      loop(api, offset, portas)
    }
    FalhaPolling(aviso, esperar_ms) -> {
      case aviso {
        Some(texto) -> logging.log(logging.Warning, texto)
        None -> Nil
      }
      process.sleep(esperar_ms)
      loop(api, offset, portas)
    }
  }
}

pub fn despachar_evento(
  evento: telegram_porta.EventoUpdate,
  api: TelegramPorta,
  portas: Portas,
) -> Nil {
  case evento {
    telegram_porta.EventoMensagemPronta(_, msg) ->
      sistema.disparar(fn() {
        let _ = api.sinalizar(msg.chat_id, telegram_porta.Digitando)
        processar(msg, portas)
      })
    telegram_porta.EventoFotoParaBaixar(_, base, file_id) ->
      sistema.disparar(fn() {
        use bytes <- baixar_ou_avisar(
          api,
          portas,
          base,
          file_id,
          telegram_porta.EnviandoFoto,
          "foto",
          "Não consegui baixar a imagem do Telegram. Tente enviar novamente.",
        )
        processar_com(base, mensagem.Imagem("image/jpeg", bytes), portas)
      })
    telegram_porta.EventoAudioParaBaixar(_, base, file_id, mime) ->
      sistema.disparar(fn() {
        use bytes <- baixar_ou_avisar(
          api,
          portas,
          base,
          file_id,
          telegram_porta.EnviandoAudio,
          "áudio",
          "Não consegui baixar o áudio do Telegram. Tente enviar novamente.",
        )
        processar_com(base, mensagem.Audio(mime, bytes), portas)
      })
    telegram_porta.EventoVideoParaBaixar(_, base, file_id, mime) ->
      sistema.disparar(fn() {
        use bytes <- baixar_ou_avisar(
          api,
          portas,
          base,
          file_id,
          telegram_porta.EnviandoVideo,
          "vídeo",
          "Não consegui baixar o vídeo do Telegram. O limite suportado pelo bot é de 20MB.",
        )
        case arquivos_temporarios.gravar(bytes) {
          Ok(caminho) ->
            processar_com(
              base,
              mensagem.Video(caminho_temp: caminho, mime: mime),
              portas,
            )
          Error(e) -> {
            logging.log(
              logging.Warning,
              "Telegram poller: falha ao salvar vídeo temporário: " <> e,
            )
            avisar(
              base.chat_id,
              "Não consegui salvar o vídeo temporariamente. Tente novamente.",
              portas,
            )
          }
        }
      })
    telegram_porta.EventoDocumentoParaBaixar(_, base, file_id, mime, file_name) ->
      sistema.disparar(fn() {
        use bytes <- baixar_ou_avisar(
          api,
          portas,
          base,
          file_id,
          telegram_porta.EnviandoDocumento,
          "documento",
          "Não consegui baixar o documento do Telegram. O limite suportado pelo bot é de 20MB.",
        )
        processar_com(
          base,
          mensagem.Documento(mime: mime, dados: bytes, nome: file_name),
          portas,
        )
      })
    telegram_porta.EventoStickerParaBaixar(_, base, file_id, mime) ->
      sistema.disparar(fn() {
        use bytes <- baixar_ou_avisar(
          api,
          portas,
          base,
          file_id,
          telegram_porta.EscolhendoFigurinha,
          "figurinha",
          "Não consegui baixar a figurinha do Telegram. Tente enviar novamente.",
        )
        processar_com(base, mensagem.Sticker(mime: mime, dados: bytes), portas)
      })
    telegram_porta.EventoArquivoMuitoGrande(_, chat_id, tamanho_mb) ->
      sistema.disparar(fn() {
        avisar(
          chat_id,
          "Não consegui baixar o arquivo do Telegram. O limite suportado pelo bot é de 20 MB (este arquivo possui cerca de "
            <> int.to_string(tamanho_mb)
            <> " MB). Se possível, envie uma versão menor ou mais curta.",
          portas,
        )
      })
    telegram_porta.EventoIgnorado(_) -> Nil
  }
}

/// Reage com 🤔, sinaliza a atividade no chat e baixa o arquivo. Se o
/// download falhar, registra no log e avisa o usuário em vez de continuar.
fn baixar_ou_avisar(
  api: TelegramPorta,
  portas: Portas,
  base: Mensagem,
  file_id: String,
  acao: AcaoChat,
  nome_midia: String,
  aviso_falha: String,
  continuar: fn(BitArray) -> Nil,
) -> Nil {
  reagir_se_possivel(base, portas)
  let _ = api.sinalizar(base.chat_id, acao)
  case api.baixar_arquivo(file_id) {
    Ok(bytes) -> continuar(bytes)
    Error(e) -> {
      logging.log(
        logging.Warning,
        "Telegram poller: falha ao baixar "
          <> nome_midia
          <> " ("
          <> file_id
          <> "): "
          <> string.inspect(e),
      )
      avisar(base.chat_id, aviso_falha, portas)
    }
  }
}

fn processar_com(base: Mensagem, corpo: Conteudo, portas: Portas) -> Nil {
  processar(Mensagem(..base, corpo: corpo), portas)
}

fn processar(msg: Mensagem, portas: Portas) -> Nil {
  let _ = tratador_mensagem.tratar(msg, portas)
  Nil
}

fn avisar(chat_id: IdChat, texto: String, portas: Portas) -> Nil {
  portas.mensageiro.enviar(chat_id, texto)
  |> sistema.registrar_falha("Falha ao avisar usuário do Telegram")
}

fn reagir_se_possivel(msg: Mensagem, portas: Portas) -> Nil {
  case msg.message_id {
    Some(mid) -> {
      let _ = portas.mensageiro.reagir(msg.chat_id, mid, msg.remetente, "🤔")
      Nil
    }
    None -> Nil
  }
}

pub fn processar_updates(
  updates: List(telegram_porta.EventoUpdate),
  offset_atual: Int,
  api: TelegramPorta,
  portas: Portas,
) -> Int {
  list.fold(updates, offset_atual, fn(maior_offset, evento) {
    despachar_evento(evento, api, portas)
    int.max(maior_offset, telegram_porta.obter_update_id(evento) + 1)
  })
}
