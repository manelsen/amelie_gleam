// Dispatcher para múltiplos provedores de IA.
// Escolhe o adaptador correto baseado no provedor e roteia chamadas.

import dominio/erro.{type Erro}
import dominio/mensagem.{type Turno}
import portas/ia_porta.{type IAPorta, IAPorta}

pub type IADispatcher {
  IADispatcher(gemini: IAPorta, openrouter: IAPorta)
}

pub type IADispatcherPorta {
  IADispatcherPorta(dispatcher: IADispatcher, provedor: String, modelo: String)
}

pub fn como_porta(disp_porta: IADispatcherPorta) -> IAPorta {
  IAPorta(
    gerar_texto: fn(prompt, historico, _modelo) {
      gerar_texto(
        disp_porta.dispatcher,
        prompt,
        historico,
        disp_porta.provedor,
        disp_porta.modelo,
      )
    },
    processar_imagem: fn(dados, mime, prompt, _modelo) {
      processar_imagem(
        disp_porta.dispatcher,
        dados,
        mime,
        prompt,
        disp_porta.provedor,
        disp_porta.modelo,
      )
    },
    processar_audio: fn(dados, mime, prompt, _modelo) {
      processar_audio(
        disp_porta.dispatcher,
        dados,
        mime,
        prompt,
        disp_porta.provedor,
        disp_porta.modelo,
      )
    },
    processar_video: fn(uri, prompt, _modelo) {
      processar_video(
        disp_porta.dispatcher,
        uri,
        prompt,
        disp_porta.provedor,
        disp_porta.modelo,
      )
    },
    processar_documento: fn(dados, mime, prompt, _modelo) {
      processar_documento(
        disp_porta.dispatcher,
        dados,
        mime,
        prompt,
        disp_porta.provedor,
        disp_porta.modelo,
      )
    },
    fazer_upload_video: fn(caminho, mime) {
      fazer_upload_video(
        disp_porta.dispatcher,
        caminho,
        mime,
        disp_porta.provedor,
      )
    },
    aguardar_video_ativo: fn(uri) {
      aguardar_video_ativo(disp_porta.dispatcher, uri, disp_porta.provedor)
    },
    deletar_arquivo: fn(uri) {
      deletar_arquivo(disp_porta.dispatcher, uri, disp_porta.provedor)
    },
  )
}

pub fn gerar_texto(
  disp: IADispatcher,
  prompt: String,
  historico: List(Turno),
  provedor: String,
  modelo: String,
) -> Result(String, Erro) {
  let porta = escolher_porta(disp, provedor)
  porta.gerar_texto(prompt, historico, modelo)
}

pub fn processar_imagem(
  disp: IADispatcher,
  dados: BitArray,
  mime: String,
  prompt: String,
  provedor: String,
  modelo: String,
) -> Result(String, Erro) {
  let porta = escolher_porta(disp, provedor)
  porta.processar_imagem(dados, mime, prompt, modelo)
}

pub fn processar_audio(
  disp: IADispatcher,
  dados: BitArray,
  mime: String,
  prompt: String,
  provedor: String,
  modelo: String,
) -> Result(String, Erro) {
  let porta = escolher_porta(disp, provedor)
  porta.processar_audio(dados, mime, prompt, modelo)
}

pub fn processar_video(
  disp: IADispatcher,
  uri: String,
  prompt: String,
  provedor: String,
  modelo: String,
) -> Result(String, Erro) {
  let porta = escolher_porta(disp, provedor)
  porta.processar_video(uri, prompt, modelo)
}

pub fn processar_documento(
  disp: IADispatcher,
  dados: BitArray,
  mime: String,
  prompt: String,
  provedor: String,
  modelo: String,
) -> Result(String, Erro) {
  let porta = escolher_porta(disp, provedor)
  porta.processar_documento(dados, mime, prompt, modelo)
}

pub fn fazer_upload_video(
  disp: IADispatcher,
  caminho: String,
  mime: String,
  provedor: String,
) -> Result(String, Erro) {
  let porta = escolher_porta(disp, provedor)
  porta.fazer_upload_video(caminho, mime)
}

pub fn aguardar_video_ativo(
  disp: IADispatcher,
  uri: String,
  provedor: String,
) -> Result(Nil, Erro) {
  let porta = escolher_porta(disp, provedor)
  porta.aguardar_video_ativo(uri)
}

pub fn deletar_arquivo(
  disp: IADispatcher,
  uri: String,
  provedor: String,
) -> Result(Nil, Erro) {
  let porta = escolher_porta(disp, provedor)
  porta.deletar_arquivo(uri)
}

fn escolher_porta(disp: IADispatcher, provedor: String) -> IAPorta {
  case provedor {
    "openrouter" -> disp.openrouter
    _ -> disp.gemini
  }
}
