import gleam/option.{type Option, None}

pub type StatusTransacao {
  Pendente
  Enviado
  Entregue
  Falha
  Descartada
}

pub type Transacao {
  Transacao(
    id: Option(Int),
    chat_id: String,
    remetente: String,
    tipo: String,
    conteudo: String,
    status: StatusTransacao,
    criado_em: Int,
    atualizado_em: Option(Int),
    tentativas: Int,
    erro: Option(String),
  )
}

pub fn novo(
  chat_id: String,
  remetente: String,
  tipo: String,
  conteudo: String,
) -> Transacao {
  Transacao(
    id: None,
    chat_id: chat_id,
    remetente: remetente,
    tipo: tipo,
    conteudo: conteudo,
    status: Pendente,
    criado_em: 0,
    atualizado_em: None,
    tentativas: 0,
    erro: None,
  )
}

pub fn status_para_string(status: StatusTransacao) -> String {
  case status {
    Pendente -> "pendente"
    Enviado -> "enviado"
    Entregue -> "entregue"
    Falha -> "falha"
    Descartada -> "descartada"
  }
}

pub fn string_para_status(s: String) -> StatusTransacao {
  case s {
    "enviado" -> Enviado
    "entregue" -> Entregue
    "falha" -> Falha
    "descartada" -> Descartada
    _ -> Pendente
  }
}
