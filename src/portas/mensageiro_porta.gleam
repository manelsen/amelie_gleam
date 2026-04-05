import dominio/erro.{type Erro}

// Contrato — o core e o shell não conhecem a plataforma de mensagens.
// Conhecem apenas este tipo.

pub type MensageiroPorta {
  MensageiroPorta(
    enviar: fn(String, String) -> Result(Nil, Erro),
    // enviar_citando(chat_id, quoted_message_id, quoted_sender, texto)
    enviar_citando: fn(String, String, String, String) -> Result(Nil, Erro),
    // reagir(chat_id, message_id, sender, emoji)
    reagir: fn(String, String, String, String) -> Result(Nil, Erro),
  )
}
