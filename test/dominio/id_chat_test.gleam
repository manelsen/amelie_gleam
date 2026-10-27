import dominio/id_chat.{CanalTelegram, CanalWhatsapp}
import gleam/list
import gleeunit/should

pub fn whatsapp_exige_usuario_e_servidor_test() {
  id_chat.whatsapp("") |> should.be_error
  id_chat.whatsapp("5531999990000") |> should.be_error
  id_chat.whatsapp("@s.whatsapp.net") |> should.be_error
  id_chat.whatsapp("5531999990000@") |> should.be_error
  id_chat.whatsapp("5531999990000@s.whatsapp.net") |> should.be_ok
}

pub fn whatsapp_nao_pode_se_passar_por_telegram_test() {
  id_chat.whatsapp("tg:123") |> should.be_error
  id_chat.whatsapp("tg:123@s.whatsapp.net") |> should.be_error
}

pub fn de_texto_e_para_texto_sao_inversos_test() {
  let textos = [
    "tg:123", "tg:-100999", "5531999990000@s.whatsapp.net",
    "5531999990000:12@s.whatsapp.net", "123456789@lid",
  ]
  let assert [Ok(a), Ok(b), Ok(c), Ok(d), Ok(e)] = {
    use texto <- list.map(textos)
    id_chat.de_texto(texto)
  }
  [a, b, c, d, e]
  |> list.map(id_chat.para_texto)
  |> should.equal(textos)
}

pub fn de_texto_recusa_telegram_sem_numero_test() {
  id_chat.de_texto("tg:") |> should.be_error
  id_chat.de_texto("tg:abc") |> should.be_error
  id_chat.de_texto("") |> should.be_error
}

pub fn canal_e_numero_telegram_test() {
  let tg = id_chat.telegram(42)
  let assert Ok(wa) = id_chat.whatsapp("5531999990000@s.whatsapp.net")
  id_chat.canal(tg) |> should.equal(CanalTelegram)
  id_chat.canal(wa) |> should.equal(CanalWhatsapp)
  id_chat.numero_telegram(tg) |> should.equal(Ok(42))
  id_chat.numero_telegram(wa) |> should.equal(Error(Nil))
}

pub fn corresponde_por_id_completo_ou_numero_test() {
  let assert Ok(wa) = id_chat.whatsapp("5531999990000:3@s.whatsapp.net")
  id_chat.corresponde(wa, "5531999990000:3@s.whatsapp.net") |> should.be_true
  id_chat.corresponde(wa, "5531999990000") |> should.be_true
  id_chat.corresponde(wa, " +55 (31) 99999-0000 ") |> should.be_true
  id_chat.corresponde(wa, "553199999") |> should.be_false
  id_chat.corresponde(wa, "") |> should.be_false
  id_chat.corresponde(id_chat.telegram(42), "tg:42") |> should.be_true
  id_chat.corresponde(id_chat.telegram(42), "42") |> should.be_true
}
