// Decodificador de Webhook da Telegram Bot API.
// Converte updates do Telegram para o tipo de domínio Mensagem e identifica
// fotos e áudios que necessitam de download assíncrono via Bot API.
// Rejeita categoricamente qualquer mensagem de grupo.

import dominio/erro.{type Erro}
import dominio/id_chat.{type IdChat}
import dominio/mensagem.{type Mensagem, Mensagem}
import gleam/bit_array
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import portas/telegram_porta.{
  type EventoUpdate, EventoArquivoMuitoGrande, EventoAudioParaBaixar,
  EventoDocumentoParaBaixar, EventoFotoParaBaixar, EventoIgnorado,
  EventoMensagemPronta, EventoStickerParaBaixar, EventoVideoParaBaixar,
}

pub type UpdateTelegram {
  UpdateTelegram(update_id: Int, message: Option(MensagemTelegram))
}

/// Arquivo de mídia anexado a uma mensagem: id para baixar via getFile, MIME
/// (do Telegram ou um padrão por tipo) e tamanho, quando informado.
pub type ArquivoTelegram {
  ArquivoTelegram(file_id: String, mime: String, tamanho: Option(Int))
}

pub type MensagemTelegram {
  MensagemTelegram(
    message_id: Int,
    date: Int,
    chat_id: Int,
    chat_type: String,
    from_id: Option(Int),
    text: Option(String),
    caption: Option(String),
    photo_file_id: Option(String),
    voice: Option(ArquivoTelegram),
    audio: Option(ArquivoTelegram),
    video: Option(ArquivoTelegram),
    video_note: Option(ArquivoTelegram),
    animation: Option(ArquivoTelegram),
    document: Option(#(ArquivoTelegram, String)),
    sticker: Option(#(String, String, Option(String))),
  )
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
    json.parse(s, update_telegram_decoder())
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
    json.parse(json_str, resposta_get_updates_decoder())
    |> result.map_error(fn(_) {
      erro.ErroValidacao("telegram", "json de getUpdates inválido")
    }),
  )
  Ok(list.map(updates, converter_update_em_evento))
}

pub const limite_download_bytes = 20_971_520

fn tamanho_em_mb(bytes: Int) -> Int {
  int.max(1, bytes / 1_048_576)
}

/// Extensões tratadas como vídeo quando o arquivo chega como documento.
const extensoes_video = [".mp4", ".mov", ".mkv", ".webm"]

pub fn converter_update_em_evento(update: UpdateTelegram) -> EventoUpdate {
  case update.message {
    // Regra de segurança/privacidade: Amélie NUNCA atua em grupos no Telegram
    Some(msg) if msg.chat_type == "private" ->
      converter_mensagem(update.update_id, msg)
    _ -> EventoIgnorado(update.update_id)
  }
}

/// Uma mensagem pode trazer mais de um campo de mídia (um GIF vem como
/// `animation` e `document`); vale o primeiro presente, nesta ordem.
fn converter_mensagem(id: Int, msg: MensagemTelegram) -> EventoUpdate {
  let base = mensagem_base(msg)
  let audio = fn(arq: ArquivoTelegram) {
    EventoAudioParaBaixar(id, base, arq.file_id, arq.mime)
  }
  let video = fn(arq: ArquivoTelegram) {
    EventoVideoParaBaixar(id, base, arq.file_id, arq.mime)
  }
  let baixar = fn(campo: Option(ArquivoTelegram), evento) {
    option.map(campo, limitar_tamanho(id, base.chat_id, _, evento))
  }
  [
    option.map(msg.photo_file_id, EventoFotoParaBaixar(id, base, _)),
    baixar(msg.voice, audio),
    baixar(msg.audio, audio),
    baixar(msg.video, video),
    baixar(msg.video_note, video),
    baixar(msg.animation, video),
    option.map(msg.document, fn(doc) {
      let #(arq, nome) = doc
      use arq <- limitar_tamanho(id, base.chat_id, arq)
      case parece_video(arq.mime, nome) {
        True -> video(arq)
        False ->
          EventoDocumentoParaBaixar(id, base, arq.file_id, arq.mime, nome)
      }
    }),
    option.map(msg.sticker, fn(sticker) {
      let #(file_id, mime, emoji) = sticker
      let base = Mensagem(..base, legenda: option.or(emoji, base.legenda))
      EventoStickerParaBaixar(id, base, file_id, mime)
    }),
    option.map(msg.text, fn(texto) {
      EventoMensagemPronta(
        id,
        Mensagem(..base, corpo: parsear_texto_ou_comando(texto)),
      )
    }),
  ]
  |> option.values
  |> list.first
  |> result.unwrap(EventoIgnorado(id))
}

fn mensagem_base(msg: MensagemTelegram) -> Mensagem {
  let sender_id = option.unwrap(msg.from_id, msg.chat_id)
  Mensagem(
    chat_id: id_chat.telegram(msg.chat_id),
    remetente: id_chat.telegram(sender_id),
    message_id: Some(int.to_string(msg.message_id)),
    corpo: mensagem.Texto(""),
    timestamp: msg.date,
    em_grupo: False,
    nome_grupo: None,
    menciona_bot: True,
    legenda: msg.caption,
  )
}

/// Arquivos acima do limite da Bot API viram aviso em vez de download.
fn limitar_tamanho(
  update_id: Int,
  chat_id: IdChat,
  arquivo: ArquivoTelegram,
  evento: fn(ArquivoTelegram) -> EventoUpdate,
) -> EventoUpdate {
  case arquivo.tamanho {
    Some(bytes) if bytes > limite_download_bytes ->
      EventoArquivoMuitoGrande(update_id, chat_id, tamanho_em_mb(bytes))
    _ -> evento(arquivo)
  }
}

fn parece_video(mime: String, nome: String) -> Bool {
  let nome = string.lowercase(nome)
  string.starts_with(mime, "video/")
  || list.any(extensoes_video, string.ends_with(nome, _))
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

fn update_telegram_decoder() -> decode.Decoder(UpdateTelegram) {
  use update_id <- decode.field("update_id", decode.int)
  use message <- decode.optional_field(
    "message",
    None,
    mensagem_telegram_decoder() |> decode.map(Some),
  )
  decode.success(UpdateTelegram(update_id: update_id, message: message))
}

fn foto_decoder() -> decode.Decoder(String) {
  use photos <- decode.then(decode.list(decode.at(["file_id"], decode.string)))
  case list.last(photos) {
    Ok(file_id) -> decode.success(file_id)
    Error(_) -> decode.failure("", "lista de fotos vazia")
  }
}

fn mime_seguro_decoder(padrao: String) -> decode.Decoder(String) {
  decode.optional(decode.string)
  |> decode.map(fn(opt) { option.unwrap(opt, padrao) })
}

/// Arquivo com `mime_type` opcional; sem ele, vale `mime_padrao`.
fn arquivo_decoder(mime_padrao: String) -> decode.Decoder(ArquivoTelegram) {
  use mime <- decode.optional_field(
    "mime_type",
    mime_padrao,
    mime_seguro_decoder(mime_padrao),
  )
  arquivo_com_mime_decoder(mime)
}

/// Arquivo cujo MIME o Telegram não informa ou não importa.
fn arquivo_com_mime_decoder(mime: String) -> decode.Decoder(ArquivoTelegram) {
  use file_id <- decode.then(decode.at(["file_id"], decode.string))
  use tamanho <- decode.optional_field(
    "file_size",
    None,
    decode.int |> decode.map(Some),
  )
  decode.success(ArquivoTelegram(file_id:, mime:, tamanho:))
}

fn documento_decoder() -> decode.Decoder(#(ArquivoTelegram, String)) {
  use arquivo <- decode.then(arquivo_decoder("application/octet-stream"))
  use file_name <- decode.optional_field("file_name", "", decode.string)
  decode.success(#(arquivo, file_name))
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

fn mensagem_telegram_decoder() -> decode.Decoder(MensagemTelegram) {
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
    foto_decoder() |> decode.map(Some),
  )
  use voice <- decode.optional_field(
    "voice",
    None,
    arquivo_decoder("audio/ogg") |> decode.map(Some),
  )
  use audio <- decode.optional_field(
    "audio",
    None,
    arquivo_decoder("audio/mpeg") |> decode.map(Some),
  )
  use video <- decode.optional_field(
    "video",
    None,
    arquivo_decoder("video/mp4") |> decode.map(Some),
  )
  use video_note <- decode.optional_field(
    "video_note",
    None,
    arquivo_com_mime_decoder("video/mp4") |> decode.map(Some),
  )
  use animation <- decode.optional_field(
    "animation",
    None,
    arquivo_com_mime_decoder("video/mp4") |> decode.map(Some),
  )
  use document <- decode.optional_field(
    "document",
    None,
    documento_decoder() |> decode.map(Some),
  )
  use sticker <- decode.optional_field(
    "sticker",
    None,
    sticker_decoder() |> decode.map(Some),
  )
  decode.success(MensagemTelegram(
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

fn resposta_get_updates_decoder() -> decode.Decoder(List(UpdateTelegram)) {
  decode.at(["result"], decode.list(update_telegram_decoder()))
}
