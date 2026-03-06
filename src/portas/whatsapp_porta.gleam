import dominio/erro.{type Erro}

// Contrato — o core e o shell não conhecem Whatsmeow.
// Conhecem apenas este tipo.

pub type WhatsappPorta {
  WhatsappPorta(
    enviar: fn(String, String) -> Result(Nil, Erro),
  )
}
