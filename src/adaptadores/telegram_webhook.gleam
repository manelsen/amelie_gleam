// Decodificador de Webhook da Telegram Bot API.
// Converte updates do Telegram para o tipo de domínio Mensagem e identifica
// fotos e áudios que necessitam de download assíncrono via Bot API.
// Rejeita categoricamente qualquer mensagem de grupo.

import dominio/erro.{type Erro}
import dominio/mensagem.{type Mensagem, Mensagem}
import gleam/bit_array
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub type TelegramUpdate {
  TelegramUpdate(update_id: Int, message: Option(TelegramMessage))
}

pub type TelegramMessage {
  TelegramMessage(
    message_id: Int,
    date: Int,
    chat_id: Int,
    chat_type: String,
    from_id: Option(Int),
    text: Option(String),
    caption: Option(String),
    photo_file_id: Option(String),
    voice: Option(#(String, String)),
    audio: Option(#(String, String)),
    video: Option(#(String, String)),
    video_note: Option(#(String, String)),
    animation: Option(#(String, String)),
    document: Option(#(String, String, String)),
    sticker: Option(#(String, String, Option(String))),
  )
}

pub type EventoUpdate {
  EventoMensagemPronta(update_id: Int, msg: Mensagem)
  EventoFotoParaBaixar(update_id: Int, base: Mensagem, file_id: String)
  EventoAudioParaBaixar(
    update_id: Int,
    base: Mensagem,
    file_id: String,
    mime: String,
  )
  EventoVideoParaBaixar(
    update_id: Int,
    base: Mensagem,
    file_id: String,
    mime: String,
  )
  EventoDocumentoParaBaixar(
    update_id: Int,
    base: Mensagem,
    file_id: String,
    mime: String,
    file_name: String,
  )
  EventoStickerParaBaixar(
    update_id: Int,
    base: Mensagem,
    file_id: String,
    mime: String,
  )
  EventoIgnorado(update_id: Int)
}

pub fn obter_update_id(evento: EventoUpdate) -> Int {
  case evento {
    EventoMensagemPronta(id, _) -> id
    EventoFotoParaBaixar(id, _, _) -> id
    EventoAudioParaBaixar(id, _, _, _) -> id
    EventoVideoParaBaixar(id, _, _, _) -> id
    EventoDocumentoParaBaixar(id, _, _, _, _) -> id
    EventoStickerParaBaixar(id, _, _, _) -> id
    EventoIgnorado(id) -> id
  }
}

pub fn extrair_evento_mensagem(evento: EventoUpdate) -> Option(Mensagem) {
  case evento {
    EventoMensagemPronta(_, msg) -> Some(msg)
    _ -> None
  }
}

pub fn parsear_evento(body: BitArray) -> Result(EventoUpdate, Erro) {
  use s <- result.try(
    bit_array.to_string(body)
    |> result.map_error(fn(_) {
      erro.ErroValidacao("telegram", "corpo inválido (não-utf8)")
    }),
  )
  use update <- result.try(
    json.parse(s, telegram_update_decoder())
    |> result.map_error(fn(_) {
      erro.ErroValidacao("telegram", "json de update inválido")
    }),
  )
  Ok(converter_update_em_evento(update))
}

pub fn parsear_update(body: BitArray) -> Result(Option(Mensagem), Erro) {
  use evento <- result.try(parsear_evento(body))
  Ok(extrair_evento_mensagem(evento))
}

pub fn extrair_updates(json_str: String) -> Result(List(EventoUpdate), Erro) {
  use updates <- result.try(
    json.parse(json_str, get_updates_response_decoder())
    |> result.map_error(fn(_) {
      erro.ErroValidacao("telegram", "json de getUpdates inválido")
    }),
  )
  Ok(list.map(updates, converter_update_em_evento))
}

pub fn converter_update_em_evento(update: TelegramUpdate) -> EventoUpdate {
  case update.message {
    None -> EventoIgnorado(update.update_id)
    Some(msg) -> {
      // Regra de segurança/privacidade: Amélie NUNCA atua em grupos no Telegram
      case msg.chat_type == "private" {
        False -> EventoIgnorado(update.update_id)
        True -> {
          let sender_id = option.unwrap(msg.from_id, msg.chat_id)
          let base =
            Mensagem(
              chat_id: "tg:" <> int.to_string(msg.chat_id),
              remetente: "tg:" <> int.to_string(sender_id),
              message_id: Some(int.to_string(msg.message_id)),
              corpo: mensagem.Texto(""),
              timestamp: msg.date,
              em_grupo: False,
              nome_grupo: None,
              menciona_bot: True,
              legenda: msg.caption,
            )

          case msg.photo_file_id {
            Some(file_id) ->
              EventoFotoParaBaixar(update.update_id, base, file_id)
            None -> {
              case msg.voice {
                Some(#(file_id, mime)) ->
                  EventoAudioParaBaixar(update.update_id, base, file_id, mime)
                None -> {
                  case msg.audio {
                    Some(#(file_id, mime)) ->
                      EventoAudioParaBaixar(
                        update.update_id,
                        base,
                        file_id,
                        mime,
                      )
                    None -> {
                      case msg.video {
                        Some(#(file_id, mime)) ->
                          EventoVideoParaBaixar(
                            update.update_id,
                            base,
                            file_id,
                            mime,
                          )
                        None -> {
                          case msg.video_note {
                            Some(#(file_id, mime)) ->
                              EventoVideoParaBaixar(
                                update.update_id,
                                base,
                                file_id,
                                mime,
                              )
                            None -> {
                              case msg.animation {
                                Some(#(file_id, mime)) ->
                                  EventoVideoParaBaixar(
                                    update.update_id,
                                    base,
                                    file_id,
                                    mime,
                                  )
                                None -> {
                                  case msg.document {
                                    Some(#(file_id, mime, file_name)) -> {
                                      let fn_lower = string.lowercase(file_name)
                                      let e_video =
                                        string.starts_with(mime, "video/")
                                        || string.ends_with(fn_lower, ".mp4")
                                        || string.ends_with(fn_lower, ".mov")
                                        || string.ends_with(fn_lower, ".mkv")
                                        || string.ends_with(fn_lower, ".webm")
                                      case e_video {
                                        True ->
                                          EventoVideoParaBaixar(
                                            update.update_id,
                                            base,
                                            file_id,
                                            mime,
                                          )
                                        False ->
                                          EventoDocumentoParaBaixar(
                                            update.update_id,
                                            base,
                                            file_id,
                                            mime,
                                            file_name,
                                          )
                                      }
                                    }
                                    None -> {
                                      case msg.sticker {
                                        Some(#(file_id, mime, emoji)) -> {
                                          let base_com_legenda = case emoji {
                                            Some(e) ->
                                              Mensagem(..base, legenda: Some(e))
                                            None -> base
                                          }
                                          EventoStickerParaBaixar(
                                            update.update_id,
                                            base_com_legenda,
                                            file_id,
                                            mime,
                                          )
                                        }
                                        None -> {
                                          case msg.text {
                                            Some(raw_text) -> {
                                              let corpo =
                                                parsear_texto_ou_comando(
                                                  raw_text,
                                                )
                                              EventoMensagemPronta(
                                                update.update_id,
                                                Mensagem(..base, corpo: corpo),
                                              )
                                            }
                                            None ->
                                              EventoIgnorado(update.update_id)
                                          }
                                        }
                                      }
                                    }
                                  }
                                }
                              }
                            }
                          }
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}

pub fn parsear_texto_ou_comando(raw_text: String) -> mensagem.Conteudo {
  let trimmed = string.trim(raw_text)
  case trimmed {
    "/" <> rest | "." <> rest -> {
      let rest = string.trim(rest)
      let #(nome, args) = case string.split_once(rest, " ") {
        Ok(#(n, a)) -> #(n, string.trim(a))
        Error(_) -> #(rest, "")
      }
      // Remove @botname de comandos como "/start@AmelieBot"
      let nome_limpo = case string.split_once(nome, "@") {
        Ok(#(n, _)) -> n
        Error(_) -> nome
      }
      mensagem.Comando(string.lowercase(nome_limpo), args)
    }
    _ -> mensagem.Texto(trimmed)
  }
}

fn telegram_update_decoder() -> decode.Decoder(TelegramUpdate) {
  use update_id <- decode.field("update_id", decode.int)
  use message <- decode.optional_field(
    "message",
    None,
    telegram_message_decoder() |> decode.map(Some),
  )
  decode.success(TelegramUpdate(update_id: update_id, message: message))
}

fn photo_file_id_decoder() -> decode.Decoder(String) {
  use photos <- decode.then(decode.list(decode.at(["file_id"], decode.string)))
  case list.last(photos) {
    Ok(file_id) -> decode.success(file_id)
    Error(_) -> decode.failure("", "lista de fotos vazia")
  }
}

fn safe_mime_decoder(padrao: String) -> decode.Decoder(String) {
  decode.optional(decode.string)
  |> decode.map(fn(opt) { option.unwrap(opt, padrao) })
}

fn voice_decoder() -> decode.Decoder(#(String, String)) {
  use file_id <- decode.then(decode.at(["file_id"], decode.string))
  use mime <- decode.optional_field(
    "mime_type",
    "audio/ogg",
    safe_mime_decoder("audio/ogg"),
  )
  decode.success(#(file_id, mime))
}

fn audio_decoder() -> decode.Decoder(#(String, String)) {
  use file_id <- decode.then(decode.at(["file_id"], decode.string))
  use mime <- decode.optional_field(
    "mime_type",
    "audio/mpeg",
    safe_mime_decoder("audio/mpeg"),
  )
  decode.success(#(file_id, mime))
}

fn video_decoder() -> decode.Decoder(#(String, String)) {
  use file_id <- decode.then(decode.at(["file_id"], decode.string))
  use mime <- decode.optional_field(
    "mime_type",
    "video/mp4",
    safe_mime_decoder("video/mp4"),
  )
  decode.success(#(file_id, mime))
}

fn video_note_decoder() -> decode.Decoder(#(String, String)) {
  use file_id <- decode.then(decode.at(["file_id"], decode.string))
  decode.success(#(file_id, "video/mp4"))
}

fn animation_decoder() -> decode.Decoder(#(String, String)) {
  use file_id <- decode.then(decode.at(["file_id"], decode.string))
  decode.success(#(file_id, "video/mp4"))
}

fn document_decoder() -> decode.Decoder(#(String, String, String)) {
  use file_id <- decode.then(decode.at(["file_id"], decode.string))
  use file_name <- decode.optional_field("file_name", "", decode.string)
  use mime <- decode.optional_field(
    "mime_type",
    "application/octet-stream",
    safe_mime_decoder("application/octet-stream"),
  )
  decode.success(#(file_id, mime, file_name))
}

fn sticker_decoder() -> decode.Decoder(#(String, String, Option(String))) {
  use file_id <- decode.then(decode.at(["file_id"], decode.string))
  use is_video <- decode.optional_field("is_video", False, decode.bool)
  use emoji <- decode.optional_field(
    "emoji",
    None,
    decode.string |> decode.map(Some),
  )
  let mime = case is_video {
    True -> "video/webm"
    False -> "image/webp"
  }
  decode.success(#(file_id, mime, emoji))
}

fn telegram_message_decoder() -> decode.Decoder(TelegramMessage) {
  use message_id <- decode.field("message_id", decode.int)
  use date <- decode.field("date", decode.int)
  use chat_id <- decode.then(decode.at(["chat", "id"], decode.int))
  use chat_type <- decode.then(decode.at(["chat", "type"], decode.string))
  use from_id <- decode.optional_field(
    "from",
    None,
    decode.at(["id"], decode.int) |> decode.map(Some),
  )
  use text <- decode.optional_field(
    "text",
    None,
    decode.string |> decode.map(Some),
  )
  use caption <- decode.optional_field(
    "caption",
    None,
    decode.string |> decode.map(Some),
  )
  use photo_file_id <- decode.optional_field(
    "photo",
    None,
    photo_file_id_decoder() |> decode.map(Some),
  )
  use voice <- decode.optional_field(
    "voice",
    None,
    voice_decoder() |> decode.map(Some),
  )
  use audio <- decode.optional_field(
    "audio",
    None,
    audio_decoder() |> decode.map(Some),
  )
  use video <- decode.optional_field(
    "video",
    None,
    video_decoder() |> decode.map(Some),
  )
  use video_note <- decode.optional_field(
    "video_note",
    None,
    video_note_decoder() |> decode.map(Some),
  )
  use animation <- decode.optional_field(
    "animation",
    None,
    animation_decoder() |> decode.map(Some),
  )
  use document <- decode.optional_field(
    "document",
    None,
    document_decoder() |> decode.map(Some),
  )
  use sticker <- decode.optional_field(
    "sticker",
    None,
    sticker_decoder() |> decode.map(Some),
  )
  decode.success(TelegramMessage(
    message_id: message_id,
    date: date,
    chat_id: chat_id,
    chat_type: chat_type,
    from_id: from_id,
    text: text,
    caption: caption,
    photo_file_id: photo_file_id,
    voice: voice,
    audio: audio,
    video: video,
    video_note: video_note,
    animation: animation,
    document: document,
    sticker: sticker,
  ))
}

fn get_updates_response_decoder() -> decode.Decoder(List(TelegramUpdate)) {
  decode.at(["result"], decode.list(telegram_update_decoder()))
}
