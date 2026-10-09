import gleam/http
import gleam/http/request
import gleeunit/should
import shell/seguranca_http

pub fn webhook_sem_segredo_configurado_fica_fechado_test() {
  request.new()
  |> request.set_method(http.Post)
  |> seguranca_http.autorizar_webhook("x-secret", "")
  |> should.equal(Error(401))
}

pub fn webhook_rejeita_token_ausente_e_incorreto_test() {
  let req = request.new() |> request.set_method(http.Post)
  seguranca_http.autorizar_webhook(req, "x-secret", "secret")
  |> should.equal(Error(401))
  req
  |> request.set_header("x-secret", "wrong")
  |> seguranca_http.autorizar_webhook("x-secret", "secret")
  |> should.equal(Error(401))
}

pub fn webhook_autenticado_exige_post_test() {
  let req = request.new() |> request.set_header("x-secret", "secret")
  seguranca_http.autorizar_webhook(req, "x-secret", "secret")
  |> should.equal(Error(405))
  req
  |> request.set_method(http.Post)
  |> seguranca_http.autorizar_webhook("x-secret", "secret")
  |> should.equal(Ok(Nil))
}

pub fn whatsapp_nao_pode_se_passar_por_telegram_test() {
  seguranca_http.identidade_whatsapp_valida("tg:123", "123@s.whatsapp.net")
  |> should.be_false
  seguranca_http.identidade_whatsapp_valida("123@g.us", "tg:123")
  |> should.be_false
  seguranca_http.identidade_whatsapp_valida("123@g.us", "456@s.whatsapp.net")
  |> should.be_true
}
