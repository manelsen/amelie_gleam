// O core não executa efeitos — prescreve Acoes.
// O shell as executa.

pub type Acao {
  EnviarTexto(para: String, corpo: String)
  EnviarReacao(para: String, emoji: String)
  EnfileirarMidia(chat_id: String, tipo: TipoMidia)
  NaoResponder
}

pub type TipoMidia {
  MidiaImagem
  MidiaAudio
  MidiaVideo
  MidiaDocumento
}
