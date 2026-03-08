// Métricas simples via OTP actor.
// Conta mensagens processadas, erros, e mídia por tipo.

import dominio/acao.{MidiaAudio, MidiaDocumento, MidiaImagem, MidiaVideo, type TipoMidia}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/otp/actor
import gleam/result

pub type Metricas =
  Subject(MensagemMetrica)

pub type MensagemMetrica {
  Incrementar(tipo: TipoContador)
  Consultar(resposta: Subject(Estado))
}

pub type TipoContador {
  MensagensProcessadas
  Erros
  MidiaPorTipo(TipoMidia)
}

pub type Estado {
  Estado(
    mensagens: Int,
    erros: Int,
    imagens: Int,
    audios: Int,
    videos: Int,
    documentos: Int,
  )
}

fn estado_inicial() -> Estado {
  Estado(
    mensagens: 0,
    erros: 0,
    imagens: 0,
    audios: 0,
    videos: 0,
    documentos: 0,
  )
}

pub fn iniciar() -> Result(Metricas, actor.StartError) {
  actor.new(estado_inicial())
  |> actor.on_message(fn(state, msg) {
    case msg {
      Incrementar(tipo) -> actor.continue(incrementar(state, tipo))
      Consultar(resposta) -> {
        process.send(resposta, state)
        actor.continue(state)
      }
    }
  })
  |> actor.start()
  |> result.map(fn(started) { started.data })
}

pub fn registrar(metricas: Metricas, tipo: TipoContador) -> Nil {
  process.send(metricas, Incrementar(tipo))
}

pub fn consultar(metricas: Metricas) -> Estado {
  let resposta = process.new_subject()
  process.send(metricas, Consultar(resposta))
  case process.receive(resposta, 5000) {
    Ok(estado) -> estado
    Error(_) -> estado_inicial()
  }
}

pub fn formatar(estado: Estado) -> String {
  "*Status das Filas*\n\n"
  <> "Mensagens processadas: `"
  <> int.to_string(estado.mensagens)
  <> "`\n"
  <> "Erros: `"
  <> int.to_string(estado.erros)
  <> "`\n\n"
  <> "*Mídia processada:*\n"
  <> "- Imagens: `"
  <> int.to_string(estado.imagens)
  <> "`\n"
  <> "- Áudios: `"
  <> int.to_string(estado.audios)
  <> "`\n"
  <> "- Vídeos: `"
  <> int.to_string(estado.videos)
  <> "`\n"
  <> "- Documentos: `"
  <> int.to_string(estado.documentos)
  <> "`"
}

fn incrementar(state: Estado, tipo: TipoContador) -> Estado {
  case tipo {
    MensagensProcessadas -> Estado(..state, mensagens: state.mensagens + 1)
    Erros -> Estado(..state, erros: state.erros + 1)
    MidiaPorTipo(MidiaImagem) -> Estado(..state, imagens: state.imagens + 1)
    MidiaPorTipo(MidiaAudio) -> Estado(..state, audios: state.audios + 1)
    MidiaPorTipo(MidiaVideo) -> Estado(..state, videos: state.videos + 1)
    MidiaPorTipo(MidiaDocumento) ->
      Estado(..state, documentos: state.documentos + 1)
  }
}
