// Diagnóstico de respostas do Gemini sem texto. Puro — não faz IO.
//
// O log não pode carregar o corpo da resposta: ele pode conter transcrição
// ou descrição da mídia do usuário. Só o motivo e o tamanho vão ao log.

import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/string

/// Resume, para log, por que uma resposta do Gemini não trouxe texto, sem
/// incluir o conteúdo. Ex.: `finishReason=SAFETY, 812 bytes`.
pub fn resumir_resposta_sem_texto(json_str: String) -> String {
  motivo(json_str)
  <> ", "
  <> int.to_string(string.byte_size(json_str))
  <> " bytes"
}

fn motivo(json_str: String) -> String {
  let decoder_finish =
    decode.at(
      ["candidates"],
      decode.list(decode.at(["finishReason"], decode.string)),
    )
  let decoder_block =
    decode.at(["promptFeedback", "blockReason"], decode.string)
  case json.parse(json_str, decoder_finish) {
    Ok([motivo, ..]) -> "finishReason=" <> motivo
    _ ->
      case json.parse(json_str, decoder_block) {
        Ok(motivo) -> "blockReason=" <> motivo
        Error(_) -> "formato inesperado"
      }
  }
}
