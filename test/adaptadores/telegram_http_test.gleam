import adaptadores/telegram_http
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

  // Emojis já permitidos ou outros passam inalterados
  telegram_http.mapear_emoji_telegram("👍")
  |> should.equal("👍")

  telegram_http.mapear_emoji_telegram("❤️")
  |> should.equal("❤️")
}
