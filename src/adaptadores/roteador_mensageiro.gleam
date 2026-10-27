// Adaptador de roteamento multicanal para MensageiroPorta.
// Direciona mensagens para WhatsApp ou Telegram conforme o canal do chat_id.

import dominio/id_chat.{CanalTelegram, CanalWhatsapp}
import portas/mensageiro_porta.{type MensageiroPorta, MensageiroPorta}

pub fn criar(
  whatsapp: MensageiroPorta,
  telegram: MensageiroPorta,
) -> MensageiroPorta {
  MensageiroPorta(
    enviar: fn(chat_id, texto) {
      case id_chat.canal(chat_id) {
        CanalTelegram -> telegram.enviar(chat_id, texto)
        CanalWhatsapp -> whatsapp.enviar(chat_id, texto)
      }
    },
    enviar_citando: fn(chat_id, quoted_id, quoted_sender, texto) {
      case id_chat.canal(chat_id) {
        CanalTelegram ->
          telegram.enviar_citando(chat_id, quoted_id, quoted_sender, texto)
        CanalWhatsapp ->
          whatsapp.enviar_citando(chat_id, quoted_id, quoted_sender, texto)
      }
    },
    reagir: fn(chat_id, message_id, sender, emoji) {
      case id_chat.canal(chat_id) {
        CanalTelegram -> telegram.reagir(chat_id, message_id, sender, emoji)
        CanalWhatsapp -> whatsapp.reagir(chat_id, message_id, sender, emoji)
      }
    },
  )
}
