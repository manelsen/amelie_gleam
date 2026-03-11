import dominio/erro.{type Erro}

// Contrato — o core e o shell não conhecem Whatsmeow.
// Conhecem apenas este tipo.

pub type WhatsappPorta {
  WhatsappPorta(
    enviar: fn(String, String) -> Result(Nil, Erro),
    // enviar_citando(chat_id, quoted_message_id, quoted_sender, texto)
    enviar_citando: fn(String, String, String, String) -> Result(Nil, Erro),
    // reagir(chat_id, message_id, sender, emoji)
    reagir: fn(String, String, String, String) -> Result(Nil, Erro),
  )
}
