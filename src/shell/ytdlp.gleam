// Baixa vídeos de plataformas externas via yt-dlp.
// Shell: tem side effects (processo externo, disco).

import dominio/erro.{type Erro}
import gleam/result

pub fn baixar(url: String) -> Result(String, Erro) {
  ytdlp_download_ffi(url)
  |> result.map_error(fn(msg) { erro.ErroComunicacao(msg) })
}

@external(erlang, "amelie_gleam_ffi", "ytdlp_download")
fn ytdlp_download_ffi(url: String) -> Result(String, String)
