import gleam/option.{type Option, None}

pub type Config {
  Config(
    chat_id: String,
    modelo: String,
    historico_max: Int,
    prompt_sistema: Option(String),
    audio_ativo: Bool,
    imagem_ativo: Bool,
    video_ativo: Bool,
    doc_ativo: Bool,
    idioma: String,
  )
}

pub fn padrao(chat_id: String) -> Config {
  Config(
    chat_id: chat_id,
    modelo: "gemini-2.5-flash-lite",
    historico_max: 50,
    prompt_sistema: None,
    audio_ativo: True,
    imagem_ativo: True,
    video_ativo: True,
    doc_ativo: True,
    idioma: "pt-BR",
  )
}
