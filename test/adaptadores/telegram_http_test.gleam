import adaptadores/telegram_http
import gleam/json
import gleam/list
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

// ---------------------------------------------------------------------------
// dividir_texto — limite de tamanho da Bot API
// ---------------------------------------------------------------------------

pub fn texto_curto_vai_inteiro_test() {
  telegram_http.dividir_texto("oi", 10) |> should.equal(["oi"])
}

pub fn corta_entre_paragrafos_test() {
  telegram_http.dividir_texto("aaaa bbbb\n\ncccc", 12)
  |> should.equal(["aaaa bbbb", "cccc"])
}

pub fn corta_entre_palavras_sem_quebra_de_linha_test() {
  telegram_http.dividir_texto("aaaa bbbb cccc", 10)
  |> should.equal(["aaaa bbbb", "cccc"])
}

pub fn palavra_maior_que_o_limite_e_cortada_test() {
  telegram_http.dividir_texto("abcdefghij", 4)
  |> should.equal(["abcd", "efgh", "ij"])
}

pub fn emoji_conta_como_duas_unidades_test() {
  // Cada 😀 ocupa 2 unidades UTF-16; 3 deles passam de 5.
  telegram_http.dividir_texto("😀😀😀", 5)
  |> should.equal(["😀😀", "😀"])
}

pub fn nenhuma_parte_passa_do_limite_real_test() {
  let texto = string.repeat("palavra ", 1500)
  let partes = telegram_http.dividir_texto(texto, telegram_http.limite_mensagem)
  list.length(partes) |> should.equal(3)
  list.all(partes, fn(p) { string.length(p) <= telegram_http.limite_mensagem })
  |> should.be_true
  string.join(partes, " ") |> string.trim |> should.equal(string.trim(texto))
}
