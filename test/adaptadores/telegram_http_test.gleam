import adaptadores/telegram_http
import gleam/json
import gleam/string
import gleeunit/should

pub fn normalizar_id_remove_prefixo_tg_test() {
  telegram_http.normalizar_id("tg:924255495")
  |> should.equal("924255495")

  telegram_http.normalizar_id("924255495")
  |> should.equal("924255495")
}

pub fn mapear_emoji_telegram_test() {
  // Emojis de espera usados no WhatsApp mapeados para o padrão permitido no Telegram
  telegram_http.mapear_emoji_telegram("⌛")
  |> should.equal("🤔")

  telegram_http.mapear_emoji_telegram("⏳")
  |> should.equal("🤔")

  // Emoji de conclusão usado no WhatsApp mapeado para 👍 permitido no Telegram
  telegram_http.mapear_emoji_telegram("🆗")
  |> should.equal("👍")

  // Aviso de falha de mídia: ⚠️ não é reação válida no Telegram
  telegram_http.mapear_emoji_telegram("⚠️")
  |> should.equal("😢")

  // Emojis já permitidos ou outros passam inalterados
  telegram_http.mapear_emoji_telegram("👍")
  |> should.equal("👍")

  telegram_http.mapear_emoji_telegram("❤️")
  |> should.equal("❤️")
}

pub fn corpo_mensagem_com_markdown_test() {
  telegram_http.corpo_mensagem(
    [#("chat_id", json.string("1")), #("text", json.string("oi"))],
    True,
  )
  |> should.equal(
    "{\"chat_id\":\"1\",\"text\":\"oi\",\"parse_mode\":\"Markdown\"}",
  )
}

pub fn corpo_mensagem_sem_markdown_omite_parse_mode_test() {
  let campos = [
    #("chat_id", json.string("1")),
    #("text", json.string("a_b *c")),
    #("reply_to_message_id", json.int(7)),
  ]
  let corpo = telegram_http.corpo_mensagem(campos, False)
  string.contains(corpo, "parse_mode") |> should.be_false
  corpo
  |> should.equal(
    "{\"chat_id\":\"1\",\"text\":\"a_b *c\",\"reply_to_message_id\":7}",
  )
}
