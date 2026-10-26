import adaptadores/gemini_url
import gleeunit/should

pub fn aceita_api_do_gemini_test() {
  gemini_url.url_da_api(
    "https://generativelanguage.googleapis.com/v1beta/files/abc123",
  )
  |> should.be_true
}

pub fn recusa_outro_host_test() {
  gemini_url.url_da_api("https://exemplo.com/v1beta/files/abc123")
  |> should.be_false
}

pub fn recusa_host_parecido_test() {
  // Sem a barra final no prefixo, isto passaria.
  gemini_url.url_da_api(
    "https://generativelanguage.googleapis.com.exemplo.com/files/x",
  )
  |> should.be_false
}

pub fn recusa_http_sem_tls_test() {
  gemini_url.url_da_api("http://generativelanguage.googleapis.com/v1beta/x")
  |> should.be_false
}
