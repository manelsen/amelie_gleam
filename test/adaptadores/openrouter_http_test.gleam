import adaptadores/openrouter_http
import gleam/json
import gleam/string
import gleeunit/should

fn parte(mime: String) -> String {
  openrouter_http.parte_midia("QUJD", mime) |> json.to_string
}

pub fn imagem_vai_como_image_url_test() {
  parte("image/jpeg")
  |> should.equal(
    "{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:image/jpeg;base64,QUJD\"}}",
  )
}

pub fn audio_de_voz_vai_como_input_audio_ogg_test() {
  parte("audio/ogg; codecs=opus")
  |> should.equal(
    "{\"type\":\"input_audio\",\"input_audio\":{\"data\":\"QUJD\",\"format\":\"ogg\"}}",
  )
}

pub fn audio_mpeg_vira_mp3_test() {
  parte("audio/mpeg") |> string.contains("\"format\":\"mp3\"") |> should.be_true
}

pub fn pdf_vai_como_file_test() {
  parte("application/pdf")
  |> should.equal(
    "{\"type\":\"file\",\"file\":{\"filename\":\"documento.pdf\",\"file_data\":\"data:application/pdf;base64,QUJD\"}}",
  )
}
