// shell/telegram_poller.gleam
// Poller assíncrono de updates do Telegram (long polling via OTP / BEAM).
// Permite recepção de mensagens sem depender de webhook ou IP público.

import adaptadores/telegram_http
import adaptadores/telegram_webhook
import dominio/erro
import dominio/mensagem.{type Mensagem, Mensagem}
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import logging
import shell/handler_mensagem.{type Portas}
import simplifile

const base_url = "https://api.telegram.org"

pub fn iniciar(bot_token: String, portas: Portas) -> Nil {
  case string.trim(bot_token) {
    "" -> Nil
    token -> {
      logging.log(logging.Info, "Iniciando Telegram poller (long polling)...")
      spawn_poller(token, 0, portas)
    }
  }
}

@external(erlang, "amelie_gleam_ffi", "spawn_fn")
fn spawn_fn(f: fn() -> a) -> Nil

@external(erlang, "amelie_gleam_ffi", "now_ms")
fn now_ms() -> Int

fn spawn_poller(bot_token: String, offset: Int, portas: Portas) -> Nil {
  spawn_fn(fn() { loop(bot_token, offset, portas) })
}

fn loop(bot_token: String, offset: Int, portas: Portas) -> Nil {
  let url =
    base_url
    <> "/bot"
    <> bot_token
    <> "/getUpdates?timeout=25&offset="
    <> int.to_string(offset)

  case request.to(url) {
    Error(_) -> {
      process.sleep(2000)
      loop(bot_token, offset, portas)
    }
    Ok(req) -> {
      let req =
        req
        |> request.set_method(http.Get)
      case httpc.send(req) {
        Ok(resp) if resp.status == 200 -> {
          case telegram_webhook.extrair_updates(resp.body) {
            Ok(updates) -> {
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
              let proximo_offset =
                processar_updates(updates, offset, bot_token, portas)
              loop(bot_token, proximo_offset, portas)
            }
            Error(e) -> {
              logging.log(
                logging.Warning,
                "Telegram poller: falha ao extrair updates: "
                  <> erro.descricao(e)
                  <> " raw="
                  <> resp.body,
              )
              process.sleep(1000)
              loop(bot_token, offset, portas)
            }
          }
        }
        Ok(resp) if resp.status == 409 -> {
          case string.contains(resp.body, "webhook is active") {
            True -> {
              logging.log(
                logging.Info,
                "Telegram poller: webhook ativo, polling desativado.",
              )
              Nil
            }
            False -> {
              logging.log(
                logging.Warning,
                "Telegram poller: conflito 409 (outra instância ativa). Aguardando 5s...",
              )
              process.sleep(5000)
              loop(bot_token, offset, portas)
            }
          }
        }
        Ok(resp) -> {
          logging.log(
            logging.Warning,
            "Telegram poller: status inesperado " <> int.to_string(resp.status),
          )
          process.sleep(2000)
          loop(bot_token, offset, portas)
        }
        Error(_) -> {
          // Erro de rede ou timeout de conexão — normal em conexões long-polling
          process.sleep(1000)
          loop(bot_token, offset, portas)
        }
      }
    }
  }
}

pub fn despachar_evento(
  evento: telegram_webhook.EventoUpdate,
  bot_token: String,
  portas: Portas,
) -> Nil {
  case evento {
    telegram_webhook.EventoMensagemPronta(_, msg) -> {
      spawn_fn(fn() {
        let _ =
          telegram_http.enviar_chat_action(bot_token, msg.chat_id, "typing")
        let _ = handler_mensagem.handle(msg, portas)
        Nil
      })
    }
    telegram_webhook.EventoFotoParaBaixar(_, base, file_id) -> {
      spawn_fn(fn() {
        reagir_se_possivel(base, portas)
        let _ =
          telegram_http.enviar_chat_action(
            bot_token,
            base.chat_id,
            "upload_photo",
          )
        case telegram_http.baixar_arquivo(bot_token, file_id) {
          Ok(bytes) -> {
            let msg =
              Mensagem(..base, corpo: mensagem.Imagem("image/jpeg", bytes))
            let _ = handler_mensagem.handle(msg, portas)
            Nil
          }
          Error(e) -> {
            logging.log(
              logging.Warning,
              "Telegram poller: falha ao baixar foto ("
                <> file_id
                <> "): "
                <> string.inspect(e),
            )
            let _ =
              portas.mensageiro.enviar(
                base.chat_id,
                "Não consegui baixar a imagem do Telegram. Tente enviar novamente.",
              )
            Nil
          }
        }
      })
    }
    telegram_webhook.EventoAudioParaBaixar(_, base, file_id, mime) -> {
      spawn_fn(fn() {
        reagir_se_possivel(base, portas)
        let _ =
          telegram_http.enviar_chat_action(
            bot_token,
            base.chat_id,
            "upload_voice",
          )
        case telegram_http.baixar_arquivo(bot_token, file_id) {
          Ok(bytes) -> {
            let msg = Mensagem(..base, corpo: mensagem.Audio(mime, bytes))
            let _ = handler_mensagem.handle(msg, portas)
            Nil
          }
          Error(e) -> {
            logging.log(
              logging.Warning,
              "Telegram poller: falha ao baixar áudio ("
                <> file_id
                <> "): "
                <> string.inspect(e),
            )
            let _ =
              portas.mensageiro.enviar(
                base.chat_id,
                "Não consegui baixar o áudio do Telegram. Tente enviar novamente.",
              )
            Nil
          }
        }
      })
    }
    telegram_webhook.EventoVideoParaBaixar(_, base, file_id, mime) -> {
      spawn_fn(fn() {
        reagir_se_possivel(base, portas)
        let _ =
          telegram_http.enviar_chat_action(
            bot_token,
            base.chat_id,
            "upload_video",
          )
        case telegram_http.baixar_arquivo(bot_token, file_id) {
          Ok(bytes) -> {
            let caminho =
              "/tmp/amelie_tg_video_"
              <> int.to_string(now_ms())
              <> "_"
              <> file_id
              <> ".mp4"
            case simplifile.write_bits(to: caminho, bits: bytes) {
              Ok(_) -> {
                let msg =
                  Mensagem(
                    ..base,
                    corpo: mensagem.Video(caminho_temp: caminho, mime: mime),
                  )
                let _ = handler_mensagem.handle(msg, portas)
                Nil
              }
              Error(e) -> {
                logging.log(
                  logging.Warning,
                  "Telegram poller: falha ao salvar vídeo temporário: "
                    <> simplifile.describe_error(e),
                )
                let _ =
                  portas.mensageiro.enviar(
                    base.chat_id,
                    "Não consegui salvar o vídeo temporariamente. Tente novamente.",
                  )
                Nil
              }
            }
          }
          Error(e) -> {
            logging.log(
              logging.Warning,
              "Telegram poller: falha ao baixar vídeo ("
                <> file_id
                <> "): "
                <> string.inspect(e),
            )
            let _ =
              portas.mensageiro.enviar(
                base.chat_id,
                "Não consegui baixar o vídeo do Telegram. O limite suportado pelo bot é de 20MB.",
              )
            Nil
          }
        }
      })
    }
    telegram_webhook.EventoDocumentoParaBaixar(
      _,
      base,
      file_id,
      mime,
      file_name,
    ) -> {
      spawn_fn(fn() {
        reagir_se_possivel(base, portas)
        let _ =
          telegram_http.enviar_chat_action(
            bot_token,
            base.chat_id,
            "upload_document",
          )
        case telegram_http.baixar_arquivo(bot_token, file_id) {
          Ok(bytes) -> {
            let msg =
              Mensagem(
                ..base,
                corpo: mensagem.Documento(
                  mime: mime,
                  dados: bytes,
                  nome: file_name,
                ),
              )
            let _ = handler_mensagem.handle(msg, portas)
            Nil
          }
          Error(e) -> {
            logging.log(
              logging.Warning,
              "Telegram poller: falha ao baixar documento ("
                <> file_id
                <> "): "
                <> string.inspect(e),
            )
            let _ =
              portas.mensageiro.enviar(
                base.chat_id,
                "Não consegui baixar o documento do Telegram. O limite suportado pelo bot é de 20MB.",
              )
            Nil
          }
        }
      })
    }
    telegram_webhook.EventoStickerParaBaixar(_, base, file_id, mime) -> {
      spawn_fn(fn() {
        reagir_se_possivel(base, portas)
        let _ =
          telegram_http.enviar_chat_action(
            bot_token,
            base.chat_id,
            "choose_sticker",
          )
        case telegram_http.baixar_arquivo(bot_token, file_id) {
          Ok(bytes) -> {
            let msg =
              Mensagem(
                ..base,
                corpo: mensagem.Sticker(mime: mime, dados: bytes),
              )
            let _ = handler_mensagem.handle(msg, portas)
            Nil
          }
          Error(e) -> {
            logging.log(
              logging.Warning,
              "Telegram poller: falha ao baixar figurinha ("
                <> file_id
                <> "): "
                <> string.inspect(e),
            )
            let _ =
              portas.mensageiro.enviar(
                base.chat_id,
                "Não consegui baixar a figurinha do Telegram. Tente enviar novamente.",
              )
            Nil
          }
        }
      })
    }
    telegram_webhook.EventoIgnorado(_) -> Nil
  }
}

fn reagir_se_possivel(msg: Mensagem, portas: Portas) -> Nil {
  case msg.message_id {
    Some(mid) -> {
      let _ = portas.mensageiro.reagir(msg.chat_id, mid, msg.remetente, "⌛")
      Nil
    }
    None -> Nil
  }
}

pub fn processar_updates(
  updates: List(telegram_webhook.EventoUpdate),
  offset_atual: Int,
  bot_token: String,
  portas: Portas,
) -> Int {
  list.fold(updates, offset_atual, fn(maior_offset, evento) {
    despachar_evento(evento, bot_token, portas)
    int.max(maior_offset, telegram_webhook.obter_update_id(evento) + 1)
  })
}
