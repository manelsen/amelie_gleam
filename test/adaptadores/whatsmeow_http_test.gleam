import adaptadores/whatsmeow_http
import gleam/httpc
import gleeunit/should

pub fn erro_estruturado_preserva_codigo_e_mensagem_test() {
  let body =
    "{\"ok\":false,\"code\":\"whatsapp_logged_out\",\"error\":\"sessão removida (401); novo pareamento necessário\"}"

  whatsmeow_http.descrever_erro_http(503, body)
  |> should.equal(
    "whatsmeow retornou status 503 [whatsapp_logged_out]: sessão removida (401); novo pareamento necessário",
  )
}

pub fn erro_textual_legado_e_preservado_test() {
  whatsmeow_http.descrever_erro_http(500, "send failed\n")
  |> should.equal("whatsmeow retornou status 500: send failed")
}

pub fn erro_sem_corpo_mantem_status_test() {
  whatsmeow_http.descrever_erro_http(502, "")
  |> should.equal("whatsmeow retornou status 502")
}

pub fn erro_de_conexao_preserva_causas_ipv4_e_ipv6_test() {
  whatsmeow_http.descrever_erro_transporte(httpc.FailedToConnect(
    httpc.Posix("econnrefused"),
    httpc.TlsAlert("unknown_ca", "certificado não confiável"),
  ))
  |> should.equal(
    "falha ao conectar ao whatsmeow bridge (IPv4: POSIX econnrefused; IPv6: TLS unknown_ca (certificado não confiável))",
  )
}

pub fn erro_de_timeout_e_explicito_test() {
  whatsmeow_http.descrever_erro_transporte(httpc.ResponseTimeout)
  |> should.equal("timeout aguardando resposta do whatsmeow bridge")
}
