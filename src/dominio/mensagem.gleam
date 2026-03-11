import gleam/option.{type Option}

pub type Mensagem {
  Mensagem(
    chat_id: String,
    remetente: String,
    message_id: Option(String),
    corpo: Conteudo,
    timestamp: Int,
    em_grupo: Bool,
    nome_grupo: Option(String),
    menciona_bot: Bool,
    legenda: Option(String),
  )
}

pub type Conteudo {
  Texto(body: String)
  Imagem(mime: String, dados: BitArray)
  Audio(mime: String, dados: BitArray)
  Video(caminho_temp: String, mime: String)
  Documento(mime: String, dados: BitArray, nome: String)
  Comando(nome: String, args: String)
}

pub type Turno {
  TurnoUsuario(conteudo: String)
  TurnoAssistente(conteudo: String)
}

pub fn e_comando(msg: Mensagem) -> Bool {
  case msg.corpo {
    Comando(..) -> True
    Texto(body) -> case body {
      "." <> _ -> True
      _ -> False
    }
    _ -> False
  }
}

pub fn e_midia(msg: Mensagem) -> Bool {
  case msg.corpo {
    Imagem(..) | Audio(..) | Video(..) | Documento(..) -> True
    _ -> False
  }
}
