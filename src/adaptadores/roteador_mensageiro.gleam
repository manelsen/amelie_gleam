// Adaptador de roteamento multicanal para MensageiroPorta.
// Direciona mensagens para WhatsApp ou Telegram baseado no prefixo do chat_id.

import gleam/string
import portas/mensageiro_porta.{type MensageiroPorta, MensageiroPorta}

pub fn criar(
  whatsapp: MensageiroPorta,
  telegram: MensageiroPorta,
) -> MensageiroPorta {
  MensageiroPorta(
    enviar: fn(chat_id, texto) {
      case e_telegram(chat_id) {
        True -> telegram.enviar(chat_id, texto)
        False -> whatsapp.enviar(chat_id, texto)
      }
    },
    enviar_citando: fn(chat_id, quoted_id, quoted_sender, texto) {
      case e_telegram(chat_id) {
        True ->
          telegram.enviar_citando(chat_id, quoted_id, quoted_sender, texto)
        False ->
          whatsapp.enviar_citando(chat_id, quoted_id, quoted_sender, texto)
      }
    },
    reagir: fn(chat_id, message_id, sender, emoji) {
      case e_telegram(chat_id) {
        True -> telegram.reagir(chat_id, message_id, sender, emoji)
        False -> whatsapp.reagir(chat_id, message_id, sender, emoji)
      }
    },
  )
}

pub fn e_telegram(chat_id: String) -> Bool {
  string.starts_with(chat_id, "tg:")
}
