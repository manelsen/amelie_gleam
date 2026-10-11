// dominio/video_contexto.gleam
// Representa o contexto temporário de um vídeo processado recentemente,
// permitindo perguntas de acompanhamento (follow-up) via Gemini File API.

pub type VideoContexto {
  VideoContexto(
    chat_id: String,
    uri: String,
    perguntas_restantes: Int,
    criado_em: Int,
  )
}
