import adaptadores/whatsmeow_webhook
import dominio/id_chat
import gleam/bit_array
import gleeunit/should
import portas/ponte_porta

fn webhook(chat_id: String, from: String) -> BitArray {
  bit_array.from_string(
    "{\"chat_id\":\""
    <> chat_id
    <> "\",\"from\":\""
    <> from
    <> "\",\"text\":\"oi\",\"ts\":1,\"em_grupo\":false}",
  )
}

pub fn webhook_whatsapp_aceita_jid_test() {
  let assert Ok(ponte_porta.Webhook(msg:, ..)) =
    whatsmeow_webhook.decodificar_webhook(webhook(
      "5531999990000@s.whatsapp.net",
      "5531999990000@s.whatsapp.net",
    ))
  id_chat.canal(msg.chat_id) |> should.equal(id_chat.CanalWhatsapp)
}

pub fn webhook_whatsapp_nao_pode_se_passar_por_telegram_test() {
  whatsmeow_webhook.decodificar_webhook(webhook("tg:123", "123@s.whatsapp.net"))
  |> should.be_error
  whatsmeow_webhook.decodificar_webhook(webhook("123@s.whatsapp.net", "tg:123"))
  |> should.be_error
  whatsmeow_webhook.decodificar_webhook(webhook(
    "5531999990000",
    "5531999990000",
  ))
  |> should.be_error
}

pub fn evento_da_ponte_decodifica_os_tres_tipos_test() {
  whatsmeow_webhook.decodificar_evento(<<"{\"evento\":\"whatsapp_up\"}":utf8>>)
  |> should.equal(Ok(ponte_porta.WhatsappVoltou))
  whatsmeow_webhook.decodificar_evento(<<
    "{\"evento\":\"pairing_code\",\"phone\":\"5531\",\"code\":\"ABCD-EFGH\"}":utf8,
  >>)
  |> should.equal(Ok(ponte_porta.CodigoPareamentoGerado("5531", "ABCD-EFGH")))
  whatsmeow_webhook.decodificar_evento(<<
    "{\"evento\":\"whatsapp_down\",\"motivo\":\"LoggedOut\"}":utf8,
  >>)
  |> should.equal(Ok(ponte_porta.WhatsappCaiu("LoggedOut")))
}

pub fn evento_da_ponte_invalido_e_recusado_test() {
  whatsmeow_webhook.decodificar_evento(<<"{}":utf8>>) |> should.be_error
  whatsmeow_webhook.decodificar_evento(<<"não é json":utf8>>) |> should.be_error
}
