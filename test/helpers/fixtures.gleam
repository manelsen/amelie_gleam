// Fixtures de teste — constantes compartilhadas entre todos os testes.

import dominio/config.{type Config, Config}
import dominio/mensagem.{
  type Mensagem, type Turno, Audio, Comando, Imagem, Mensagem, Texto,
  TurnoAssistente, TurnoUsuario, Video,
}
import gleam/option.{None, Some}

pub fn chat_id() -> String {
  "5531999990000@c.us"
}

pub fn remetente() -> String {
  "5531888880000@c.us"
}

pub fn config_padrao() -> Config {
  Config(
    chat_id: chat_id(),
    modelo: "gemini-2.5-flash-lite",
    historico_max: 10,
    prompt_sistema: None,
    audio_ativo: True,
    imagem_ativo: True,
    video_ativo: True,
    doc_ativo: True,
    idioma: "pt-BR",
  )
}

pub fn config_com_prompt() -> Config {
  Config(
    ..config_padrao(),
    prompt_sistema: Some("Você é um assistente de testes."),
  )
}

pub fn config_midia_off() -> Config {
  Config(
    ..config_padrao(),
    audio_ativo: False,
    imagem_ativo: False,
    video_ativo: False,
    doc_ativo: False,
  )
}

pub fn mensagem_texto(body: String) -> Mensagem {
  Mensagem(
    chat_id: chat_id(),
    remetente: remetente(),
    corpo: Texto(body),
    timestamp: 1_700_000_000,
    em_grupo: False,
    menciona_bot: False,
  )
}

pub fn mensagem_comando(nome: String, args: String) -> Mensagem {
  Mensagem(
    chat_id: chat_id(),
    remetente: remetente(),
    corpo: Comando(nome, args),
    timestamp: 1_700_000_000,
    em_grupo: False,
    menciona_bot: False,
  )
}

pub fn mensagem_imagem() -> Mensagem {
  Mensagem(
    chat_id: chat_id(),
    remetente: remetente(),
    corpo: Imagem(mime: "image/jpeg", dados: <<255, 216, 255>>),
    timestamp: 1_700_000_000,
    em_grupo: False,
    menciona_bot: False,
  )
}

pub fn mensagem_audio() -> Mensagem {
  Mensagem(
    chat_id: chat_id(),
    remetente: remetente(),
    corpo: Audio(mime: "audio/ogg; codecs=opus", dados: <<79, 103, 103>>),
    timestamp: 1_700_000_000,
    em_grupo: False,
    menciona_bot: False,
  )
}

pub fn mensagem_video() -> Mensagem {
  Mensagem(
    chat_id: chat_id(),
    remetente: remetente(),
    corpo: Video(caminho_temp: "/tmp/video.mp4", mime: "video/mp4"),
    timestamp: 1_700_000_000,
    em_grupo: False,
    menciona_bot: False,
  )
}

pub fn historico_vazio() -> List(Turno) {
  []
}

pub fn historico_com_turnos() -> List(Turno) {
  [
    TurnoUsuario("Olá"),
    TurnoAssistente("Olá! Como posso ajudar?"),
    TurnoUsuario("Tudo bem?"),
    TurnoAssistente("Tudo bem! E você?"),
  ]
}
