// shell/receptor_telegram.gleam
// Poller assíncrono de updates do Telegram (long polling via OTP / BEAM).
// Permite recepção de mensagens sem depender de webhook ou IP público.
// Toda chamada à Bot API passa pela TelegramPorta.

import dominio/id_chat.{type IdChat}
import dominio/mensagem.{type Conteudo, type Mensagem, Mensagem}
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import logging
import portas/telegram_porta.{
  type AcaoChat, type TelegramPorta, FalhaPolling, NovosUpdates, OutraInstancia,
  WebhookAtivo,
}
import shell/arquivos_temporarios
import shell/fila_atrasadas.{type FilaAtrasadas}
import shell/sistema
import shell/tratador_mensagem.{type Portas}

pub fn iniciar(
  api: TelegramPorta,
  portas: Portas,
  atrasadas: FilaAtrasadas,
) -> Nil {
  logging.log(logging.Info, "Iniciando Telegram poller (long polling)...")
  sistema.disparar(fn() { loop(api, 0, portas, atrasadas) })
}

fn loop(
  api: TelegramPorta,
  offset: Int,
  portas: Portas,
  atrasadas: FilaAtrasadas,
) -> Nil {
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
      loop(
        api,
        processar_updates(updates, offset, api, portas, atrasadas),
        portas,
        atrasadas,
      )
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
      loop(api, offset, portas, atrasadas)
    }
    FalhaPolling(aviso, esperar_ms) -> {
      case aviso {
        Some(texto) -> logging.log(logging.Warning, texto)
        None -> Nil
      }
      process.sleep(esperar_ms)
      loop(api, offset, portas, atrasadas)
    }
  }
}

/// Despacha o update em processo isolado. Mensagens enviadas enquanto a
/// Amélie estava fora do ar (o `getUpdates` entrega o acumulado de uma vez)
/// vão para a fila serial, uma por vez e sem contar como rajada.
pub fn despachar_evento(
  evento: telegram_porta.EventoUpdate,
  api: TelegramPorta,
  portas: Portas,
  atrasadas: FilaAtrasadas,
) -> Nil {
  let atrasada = case mensagem_do_evento(evento) {
    Some(msg) -> fila_atrasadas.e_atrasada(msg.timestamp, sistema.agora_s())
    None -> False
  }
  let tratar = case atrasada {
    True -> tratador_mensagem.tratar_atrasada
    False -> tratador_mensagem.tratar
  }
  let processar = fn(msg) {
    let _ = tratar(msg, portas)
    Nil
  }

  case tarefa_do_evento(evento, api, portas, processar), atrasada {
    None, _ -> Nil
    Some(tarefa), True -> fila_atrasadas.enfileirar(atrasadas, tarefa)
    Some(tarefa), False -> sistema.disparar(tarefa)
  }
}

fn mensagem_do_evento(evento: telegram_porta.EventoUpdate) -> Option(Mensagem) {
  case evento {
    telegram_porta.EventoMensagemPronta(_, msg) -> Some(msg)
    telegram_porta.EventoFotoParaBaixar(_, base, ..)
    | telegram_porta.EventoAudioParaBaixar(_, base, ..)
    | telegram_porta.EventoVideoParaBaixar(_, base, ..)
    | telegram_porta.EventoDocumentoParaBaixar(_, base, ..)
    | telegram_porta.EventoStickerParaBaixar(_, base, ..) -> Some(base)
    telegram_porta.EventoArquivoMuitoGrande(..)
    | telegram_porta.EventoIgnorado(_) -> None
  }
}

fn tarefa_do_evento(
  evento: telegram_porta.EventoUpdate,
  api: TelegramPorta,
  portas: Portas,
  processar: fn(Mensagem) -> Nil,
) -> Option(fn() -> Nil) {
  let processar_com = fn(base: Mensagem, corpo: Conteudo) {
    processar(Mensagem(..base, corpo: corpo))
  }
  case evento {
    telegram_porta.EventoMensagemPronta(_, msg) ->
      Some(fn() {
        let _ = api.sinalizar(msg.chat_id, telegram_porta.Digitando)
        processar(msg)
      })
    telegram_porta.EventoFotoParaBaixar(_, base, file_id) ->
      Some(fn() {
        use bytes <- baixar_ou_avisar(
          api,
          portas,
          base,
          file_id,
          telegram_porta.EnviandoFoto,
          "foto",
          "Não consegui baixar a imagem do Telegram. Tente enviar novamente.",
        )
        processar_com(base, mensagem.Imagem("image/jpeg", bytes))
      })
    telegram_porta.EventoAudioParaBaixar(_, base, file_id, mime) ->
      Some(fn() {
        use bytes <- baixar_ou_avisar(
          api,
          portas,
          base,
          file_id,
          telegram_porta.EnviandoAudio,
          "áudio",
          "Não consegui baixar o áudio do Telegram. Tente enviar novamente.",
        )
        processar_com(base, mensagem.Audio(mime, bytes))
      })
    telegram_porta.EventoVideoParaBaixar(_, base, file_id, mime) ->
      Some(fn() {
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
      Some(fn() {
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
        )
      })
    telegram_porta.EventoStickerParaBaixar(_, base, file_id, mime) ->
      Some(fn() {
        use bytes <- baixar_ou_avisar(
          api,
          portas,
          base,
          file_id,
          telegram_porta.EscolhendoFigurinha,
          "figurinha",
          "Não consegui baixar a figurinha do Telegram. Tente enviar novamente.",
        )
        processar_com(base, mensagem.Sticker(mime: mime, dados: bytes))
      })
    telegram_porta.EventoArquivoMuitoGrande(_, chat_id, tamanho_mb) ->
      Some(fn() {
        avisar(
          chat_id,
          "Não consegui baixar o arquivo do Telegram. O limite suportado pelo bot é de 20 MB (este arquivo possui cerca de "
            <> int.to_string(tamanho_mb)
            <> " MB). Se possível, envie uma versão menor ou mais curta.",
          portas,
        )
      })
    telegram_porta.EventoIgnorado(_) -> None
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
  atrasadas: FilaAtrasadas,
) -> Int {
  list.fold(updates, offset_atual, fn(maior_offset, evento) {
    despachar_evento(evento, api, portas, atrasadas)
    int.max(maior_offset, telegram_porta.obter_update_id(evento) + 1)
  })
}
