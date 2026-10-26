import adaptadores/gemini_diagnostico
import gleam/string
import gleeunit/should

pub fn bloqueio_por_seguranca_test() {
  let corpo =
    "{\"candidates\":[{\"finishReason\":\"SAFETY\",\"safetyRatings\":[]}]}"
  gemini_diagnostico.resumir_resposta_sem_texto(corpo)
  |> should.equal("finishReason=SAFETY, 61 bytes")
}

pub fn bloqueio_do_prompt_test() {
  let corpo = "{\"promptFeedback\":{\"blockReason\":\"OTHER\"}}"
  gemini_diagnostico.resumir_resposta_sem_texto(corpo)
  |> should.equal("blockReason=OTHER, 42 bytes")
}

pub fn formato_inesperado_test() {
  gemini_diagnostico.resumir_resposta_sem_texto("não é json")
  |> should.equal("formato inesperado, 12 bytes")
}

pub fn nunca_inclui_conteudo_test() {
  let segredo = "transcrição privada do áudio do usuário"
  let corpo =
    "{\"candidates\":[{\"finishReason\":\"MAX_TOKENS\",\"content\":{\"parts\":[{\"x\":\""
    <> segredo
    <> "\"}]}}]}"
  gemini_diagnostico.resumir_resposta_sem_texto(corpo)
  |> string.contains(segredo)
  |> should.be_false
}
