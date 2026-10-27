// portas/video_contexto_porta.gleam
// Porta para armazenamento e ciclo de vida do contexto temporário de vídeos.

import dominio/erro.{type Erro}
import dominio/id_chat.{type IdChat}
import dominio/video_contexto.{type VideoContexto}
import gleam/option.{type Option}

pub type VideoContextoPorta {
  VideoContextoPorta(
    obter: fn(IdChat) -> Result(Option(VideoContexto), Erro),
    salvar: fn(VideoContexto) -> Result(Nil, Erro),
    decrementar_perguntas: fn(IdChat) -> Result(Int, Erro),
    remover: fn(IdChat) -> Result(Option(String), Erro),
    limpar_expirados: fn(Int) -> Result(List(String), Erro),
  )
}
