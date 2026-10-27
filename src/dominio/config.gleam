import dominio/id_chat.{type IdChat}
import dominio/provedor.{type Provedor}
import gleam/option.{type Option, None}

pub type ModoDescricao {
  Curto
  Longo
  Normal
}

pub type Config {
  Config(
    chat_id: IdChat,
    provedor: Provedor,
    modelo: String,
    historico_max: Int,
    prompt_sistema: Option(String),
    audio_ativo: Bool,
    imagem_ativo: Bool,
    video_ativo: Bool,
    doc_ativo: Bool,
    legenda_ativo: Bool,
    idioma: String,
    modo_descricao: ModoDescricao,
  )
}

pub fn padrao(chat_id: IdChat) -> Config {
  Config(
    chat_id: chat_id,
    provedor: provedor.Gemini,
    modelo: "gemini-3.5-flash-lite",
    historico_max: 50,
    prompt_sistema: None,
    audio_ativo: True,
    imagem_ativo: True,
    video_ativo: True,
    doc_ativo: True,
    legenda_ativo: False,
    idioma: "pt-BR",
    modo_descricao: Curto,
  )
}

pub fn modo_para_string(modo: ModoDescricao) -> String {
  case modo {
    Curto -> "curto"
    Longo -> "longo"
    Normal -> "normal"
  }
}

pub fn string_para_modo(s: String) -> ModoDescricao {
  case s {
    "longo" -> Longo
    "normal" -> Normal
    _ -> Curto
  }
}
