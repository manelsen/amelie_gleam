// Dispatcher para múltiplos provedores de IA.
// Escolhe o adaptador correto baseado no provedor e roteia chamadas.

import dominio/erro.{type Erro}
import dominio/mensagem.{type Turno}
import dominio/provedor.{type Provedor, Gemini, OpenRouter}
import portas/ia_porta.{type IAPorta, IAPorta}

pub type DespachanteIA {
  DespachanteIA(gemini: IAPorta, openrouter: IAPorta)
}

pub type DespachanteIAPorta {
  DespachanteIAPorta(
    despachante: DespachanteIA,
    provedor: Provedor,
    modelo: String,
  )
}

pub fn como_porta(disp_porta: DespachanteIAPorta) -> IAPorta {
  IAPorta(
    gerar_texto: fn(prompt, historico, _modelo) {
      gerar_texto(
        disp_porta.despachante,
        prompt,
        historico,
        disp_porta.provedor,
        disp_porta.modelo,
      )
    },
    processar_imagem: fn(dados, mime, prompt, _modelo) {
      processar_imagem(
        disp_porta.despachante,
        dados,
        mime,
        prompt,
        disp_porta.provedor,
        disp_porta.modelo,
      )
    },
    processar_audio: fn(dados, mime, prompt, _modelo) {
      processar_audio(
        disp_porta.despachante,
        dados,
        mime,
        prompt,
        disp_porta.provedor,
        disp_porta.modelo,
      )
    },
    processar_video: fn(uri, prompt, _modelo) {
      processar_video(
        disp_porta.despachante,
        uri,
        prompt,
        disp_porta.provedor,
        disp_porta.modelo,
      )
    },
    processar_documento: fn(dados, mime, prompt, _modelo) {
      processar_documento(
        disp_porta.despachante,
        dados,
        mime,
        prompt,
        disp_porta.provedor,
        disp_porta.modelo,
      )
    },
    fazer_upload_video: fn(caminho, mime) {
      fazer_upload_video(
        disp_porta.despachante,
        caminho,
        mime,
        disp_porta.provedor,
      )
    },
    aguardar_video_ativo: fn(uri) {
      aguardar_video_ativo(disp_porta.despachante, uri, disp_porta.provedor)
    },
    deletar_arquivo: fn(uri) {
      deletar_arquivo(disp_porta.despachante, uri, disp_porta.provedor)
    },
  )
}

pub fn gerar_texto(
  disp: DespachanteIA,
  prompt: String,
  historico: List(Turno),
  provedor: Provedor,
  modelo: String,
) -> Result(String, Erro) {
  let porta = escolher_porta(disp, provedor)
  porta.gerar_texto(prompt, historico, modelo)
}

pub fn processar_imagem(
  disp: DespachanteIA,
  dados: BitArray,
  mime: String,
  prompt: String,
  provedor: Provedor,
  modelo: String,
) -> Result(String, Erro) {
  let porta = escolher_porta(disp, provedor)
  porta.processar_imagem(dados, mime, prompt, modelo)
}

pub fn processar_audio(
  disp: DespachanteIA,
  dados: BitArray,
  mime: String,
  prompt: String,
  provedor: Provedor,
  modelo: String,
) -> Result(String, Erro) {
  let porta = escolher_porta(disp, provedor)
  porta.processar_audio(dados, mime, prompt, modelo)
}

pub fn processar_video(
  disp: DespachanteIA,
  uri: String,
  prompt: String,
  provedor: Provedor,
  modelo: String,
) -> Result(String, Erro) {
  let porta = escolher_porta(disp, provedor)
  porta.processar_video(uri, prompt, modelo)
}

pub fn processar_documento(
  disp: DespachanteIA,
  dados: BitArray,
  mime: String,
  prompt: String,
  provedor: Provedor,
  modelo: String,
) -> Result(String, Erro) {
  let porta = escolher_porta(disp, provedor)
  porta.processar_documento(dados, mime, prompt, modelo)
}

pub fn fazer_upload_video(
  disp: DespachanteIA,
  caminho: String,
  mime: String,
  provedor: Provedor,
) -> Result(String, Erro) {
  let porta = escolher_porta(disp, provedor)
  porta.fazer_upload_video(caminho, mime)
}

pub fn aguardar_video_ativo(
  disp: DespachanteIA,
  uri: String,
  provedor: Provedor,
) -> Result(Nil, Erro) {
  let porta = escolher_porta(disp, provedor)
  porta.aguardar_video_ativo(uri)
}

pub fn deletar_arquivo(
  disp: DespachanteIA,
  uri: String,
  provedor: Provedor,
) -> Result(Nil, Erro) {
  let porta = escolher_porta(disp, provedor)
  porta.deletar_arquivo(uri)
}

fn escolher_porta(disp: DespachanteIA, provedor: Provedor) -> IAPorta {
  case provedor {
    Gemini -> disp.gemini
    OpenRouter -> disp.openrouter
  }
}
