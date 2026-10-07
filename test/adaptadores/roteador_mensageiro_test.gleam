import adaptadores/roteador_mensageiro
import adaptadores/telegram_http
import gleam/erlang/process
import gleeunit/should
import portas/mensageiro_porta.{MensageiroPorta}

fn criar_capturador(
  ref: process.Subject(#(String, String, String)),
) -> mensageiro_porta.MensageiroPorta {
  MensageiroPorta(
    enviar: fn(chat_id, texto) {
      process.send(ref, #("enviar", chat_id, texto))
      Ok(Nil)
    },
    enviar_citando: fn(chat_id, quoted_id, _sender, texto) {
      process.send(ref, #("enviar_citando:" <> quoted_id, chat_id, texto))
      Ok(Nil)
    },
    reagir: fn(chat_id, msg_id, _sender, emoji) {
      process.send(ref, #("reagir:" <> msg_id, chat_id, emoji))
      Ok(Nil)
    },
  )
}

pub fn roteia_para_telegram_quando_prefixo_tg_test() {
  let ref_wa = process.new_subject()
  let ref_tg = process.new_subject()
  let wa = criar_capturador(ref_wa)
  let tg = criar_capturador(ref_tg)
  let roteador = roteador_mensageiro.criar(wa, tg)

  // Enviar para chat Telegram
  let _ = roteador.enviar("tg:123456", "Olá pelo Telegram")
  let assert Ok(#("enviar", "tg:123456", "Olá pelo Telegram")) =
    process.receive(ref_tg, 100)

  // Nenhuma mensagem deve ter ido para o WhatsApp
  process.receive(ref_wa, 50) |> should.be_error
}

pub fn roteia_para_whatsapp_quando_sem_prefixo_tg_test() {
  let ref_wa = process.new_subject()
  let ref_tg = process.new_subject()
  let wa = criar_capturador(ref_wa)
  let tg = criar_capturador(ref_tg)
  let roteador = roteador_mensageiro.criar(wa, tg)

  // Enviar para WhatsApp
  let _ = roteador.enviar("5531999990000@c.us", "Olá pelo WhatsApp")
  let assert Ok(#("enviar", "5531999990000@c.us", "Olá pelo WhatsApp")) =
    process.receive(ref_wa, 100)

  // Nenhuma mensagem deve ter ido para o Telegram
  process.receive(ref_tg, 50) |> should.be_error
}

pub fn normalizar_id_remove_prefixo_tg_test() {
  telegram_http.normalizar_id("tg:987654") |> should.equal("987654")
  telegram_http.normalizar_id("987654") |> should.equal("987654")
}
