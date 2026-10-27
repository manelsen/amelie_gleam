import amelie_gleam
import dominio/id_chat
import gleam/bit_array
import gleam/bytes_tree
import gleeunit
import gleeunit/should
import helpers/portas_fake
import mist
import sqlight

pub fn main() {
  gleeunit.main()
}

pub fn tratar_health_retorna_json_com_status_test() {
  use conn <- sqlight.with_connection(":memory:")
  let resp =
    amelie_gleam.tratar_saude(
      conn,
      portas_fake.ponte_inacessivel(),
      "fake-token",
    )
  resp.status |> should.equal(200)
}

pub fn health_publico_nao_expoe_detalhes_test() {
  use conn <- sqlight.with_connection(":memory:")
  let resp =
    amelie_gleam.tratar_saude_publica(conn, portas_fake.ponte_inacessivel())
  resp.status |> should.equal(200)
  let assert mist.Bytes(corpo) = resp.body
  bytes_tree.to_bit_array(corpo)
  |> should.equal(<<"{\"status\":\"degraded\"}":utf8>>)
}

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
  let assert Ok(amelie_gleam.Webhook(msg:, ..)) =
    amelie_gleam.decodificar_webhook(webhook(
      "5531999990000@s.whatsapp.net",
      "5531999990000@s.whatsapp.net",
    ))
  id_chat.canal(msg.chat_id) |> should.equal(id_chat.CanalWhatsapp)
}

pub fn webhook_whatsapp_nao_pode_se_passar_por_telegram_test() {
  amelie_gleam.decodificar_webhook(webhook("tg:123", "123@s.whatsapp.net"))
  |> should.be_error
  amelie_gleam.decodificar_webhook(webhook("123@s.whatsapp.net", "tg:123"))
  |> should.be_error
  amelie_gleam.decodificar_webhook(webhook("5531999990000", "5531999990000"))
  |> should.be_error
}
