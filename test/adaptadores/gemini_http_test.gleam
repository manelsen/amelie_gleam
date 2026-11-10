import adaptadores/gemini_http
import gleeunit/should

pub fn junta_todas_as_partes_de_texto_test() {
  "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"Olá, \"},{\"text\":\"mundo.\"}]}}]}"
  |> gemini_http.extrair_texto_resposta
  |> should.equal(Ok("Olá, mundo."))
}

pub fn parte_sem_texto_nao_derruba_a_resposta_test() {
  "{\"candidates\":[{\"content\":{\"parts\":[{\"thoughtSignature\":\"abc\"},{\"text\":\"Resposta.\"}]}}]}"
  |> gemini_http.extrair_texto_resposta
  |> should.equal(Ok("Resposta."))
}

pub fn parte_de_pensamento_fica_de_fora_test() {
  "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"rascunho\",\"thought\":true},{\"text\":\"Final.\"}]}}]}"
  |> gemini_http.extrair_texto_resposta
  |> should.equal(Ok("Final."))
}

pub fn resposta_sem_texto_e_erro_test() {
  "{\"candidates\":[{\"finishReason\":\"SAFETY\"}]}"
  |> gemini_http.extrair_texto_resposta
  |> should.be_error
}
