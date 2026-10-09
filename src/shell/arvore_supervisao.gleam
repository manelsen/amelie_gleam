// shell/arvore_supervisao.gleam
// Árvore de supervisão OTP para os atores de suporte do shell da Amélie.
// Garante auto-recuperação transparente (let it crash) com estratégia OneForOne
// e subjects nomeados (named_subject) para comunicação estável entre reinícios.

import gleam/erlang/process.{type Subject}
import gleam/otp/actor
import gleam/otp/static_supervisor
import portas/mensageiro_porta.{type MensageiroPorta}
import portas/transacao_porta.{type TransacaoPorta}
import shell/cache_ia
import shell/circuit_breaker
import shell/fila_midia
import shell/fila_offline
import shell/metricas

pub type ProcessosSupervisionados {
  ProcessosSupervisionados(
    cb_gemini: Subject(circuit_breaker.Mensagem),
    cb_openrouter: Subject(circuit_breaker.Mensagem),
    cache_gemini: Subject(cache_ia.MensagemCache),
    cache_openrouter: Subject(cache_ia.MensagemCache),
    metricas: Subject(metricas.MensagemMetrica),
    fila: fila_midia.FilasMidia,
    fila_offline: Subject(fila_offline.Mensagem),
  )
}

pub fn iniciar(
  transacoes: TransacaoPorta,
  mensageiro: MensageiroPorta,
) -> Result(
  #(static_supervisor.Supervisor, ProcessosSupervisionados),
  actor.StartError,
) {
  let name_cb_gemini = process.new_name("amelie_cb_gemini")
  let name_cb_openrouter = process.new_name("amelie_cb_openrouter")
  let name_cache_gemini = process.new_name("amelie_cache_gemini")
  let name_cache_openrouter = process.new_name("amelie_cache_openrouter")
  let name_metricas = process.new_name("amelie_metricas")
  let name_fila_img = process.new_name("amelie_fila_imagem")
  let name_fila_aud = process.new_name("amelie_fila_audio")
  let name_fila_vid = process.new_name("amelie_fila_video")
  let name_fila_doc = process.new_name("amelie_fila_documento")
  let name_fila_stk = process.new_name("amelie_fila_sticker")
  let name_fila_offline = process.new_name("amelie_fila_offline")

  let procs =
    ProcessosSupervisionados(
      cb_gemini: process.named_subject(name_cb_gemini),
      cb_openrouter: process.named_subject(name_cb_openrouter),
      cache_gemini: process.named_subject(name_cache_gemini),
      cache_openrouter: process.named_subject(name_cache_openrouter),
      metricas: process.named_subject(name_metricas),
      fila: fila_midia.FilasMidia(
        imagem: process.named_subject(name_fila_img),
        audio: process.named_subject(name_fila_aud),
        video: process.named_subject(name_fila_vid),
        documento: process.named_subject(name_fila_doc),
        sticker: process.named_subject(name_fila_stk),
      ),
      fila_offline: process.named_subject(name_fila_offline),
    )

  let builder =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.restart_tolerance(intensity: 5, period: 10)
    |> static_supervisor.add(circuit_breaker.supervisionado(name_cb_gemini))
    |> static_supervisor.add(circuit_breaker.supervisionado(name_cb_openrouter))
    |> static_supervisor.add(cache_ia.supervisionado(name_cache_gemini))
    |> static_supervisor.add(cache_ia.supervisionado(name_cache_openrouter))
    |> static_supervisor.add(metricas.supervisionado(name_metricas))
    |> static_supervisor.add(fila_midia.supervisionado_um(name_fila_img))
    |> static_supervisor.add(fila_midia.supervisionado_um(name_fila_aud))
    |> static_supervisor.add(fila_midia.supervisionado_um(name_fila_vid))
    |> static_supervisor.add(fila_midia.supervisionado_um(name_fila_doc))
    |> static_supervisor.add(fila_midia.supervisionado_um(name_fila_stk))
    |> static_supervisor.add(fila_offline.supervisionado(
      transacoes,
      mensageiro,
      3,
      name_fila_offline,
    ))

  case static_supervisor.start(builder) {
    Ok(started) -> Ok(#(started.data, procs))
    Error(err) -> Error(err)
  }
}
