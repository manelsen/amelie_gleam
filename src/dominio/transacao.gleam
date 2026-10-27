import dominio/acao.{
  type TipoMidia, MidiaAudio, MidiaDocumento, MidiaImagem, MidiaSticker,
  MidiaVideo,
}
import gleam/option.{type Option, None}

/// Quem envia as transações registradas pela auditoria de entrega.
pub const remetente_bot = "amelie"

/// O que foi entregue ao usuário. Gravado como texto na coluna `tipo`.
pub type TipoEntrega {
  /// Resposta pronta: comandos, avisos e erros.
  RespostaTexto
  /// Texto gerado pela IA a partir da conversa.
  RespostaIA
  /// Descrição de uma mídia enviada pelo usuário.
  DescricaoMidia(TipoMidia)
}

pub fn tipo_entrega_para_string(tipo: TipoEntrega) -> String {
  case tipo {
    RespostaTexto -> "texto"
    RespostaIA -> "ia_texto"
    DescricaoMidia(MidiaImagem) -> "imagem"
    DescricaoMidia(MidiaAudio) -> "audio"
    DescricaoMidia(MidiaVideo) -> "video"
    DescricaoMidia(MidiaDocumento) -> "documento"
    DescricaoMidia(MidiaSticker) -> "sticker"
  }
}

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

pub fn novo(chat_id: String, tipo: TipoEntrega, conteudo: String) -> Transacao {
  Transacao(
    id: None,
    chat_id: chat_id,
    remetente: remetente_bot,
    tipo: tipo_entrega_para_string(tipo),
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
