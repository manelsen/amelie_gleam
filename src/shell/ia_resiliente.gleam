// Camada de resiliência para chamadas de IA.
// Adiciona retry com backoff exponencial e circuit breaker sobre qualquer IAPorta.
// Equivalente ao executarComResiliencia do GerenciadorAI.js do legado.

import dominio/erro.{type Erro}
import gleam/erlang/process.{type Subject}
import gleam/option
import gleam/string
import portas/ia_porta.{type IAPorta, IAPorta}
import shell/cache_ia.{type CacheIA}
import shell/circuit_breaker.{type Mensagem as CbMsg}

const max_tentativas = 3

const espera_base_ms = 1000

/// Envolve uma IAPorta com cache de respostas, retry com backoff e circuit breaker.
pub fn envolver(porta: IAPorta, cb: Subject(CbMsg), cache: CacheIA) -> IAPorta {
  IAPorta(
    gerar_texto: fn(prompt, historico, modelo) {
      let k = cache_ia.chave(prompt, modelo)
      case cache_ia.obter(cache, k) {
        option.Some(cached) -> Ok(cached)
        option.None ->
          case
            com_retry(
              fn() { porta.gerar_texto(prompt, historico, modelo) },
              cb,
              1,
            )
          {
            Ok(r) -> {
              cache_ia.guardar(cache, k, r)
              Ok(r)
            }
            err -> err
          }
      }
    },
    processar_imagem: fn(dados, mime, prompt, modelo) {
      com_retry(
        fn() { porta.processar_imagem(dados, mime, prompt, modelo) },
        cb,
        1,
      )
    },
    processar_audio: fn(dados, mime, modelo) {
      com_retry(fn() { porta.processar_audio(dados, mime, modelo) }, cb, 1)
    },
    processar_video: fn(uri, prompt, modelo) {
      com_retry(fn() { porta.processar_video(uri, prompt, modelo) }, cb, 1)
    },
    processar_documento: fn(dados, mime, prompt, modelo) {
      com_retry(
        fn() { porta.processar_documento(dados, mime, prompt, modelo) },
        cb,
        1,
      )
    },
    fazer_upload_video: fn(caminho, mime) {
      com_retry(fn() { porta.fazer_upload_video(caminho, mime) }, cb, 1)
    },
    aguardar_video_ativo: fn(uri) {
      com_retry(fn() { porta.aguardar_video_ativo(uri) }, cb, 1)
    },
    // Deleção é best-effort: sem retry nem CB.
    deletar_arquivo: fn(uri) { porta.deletar_arquivo(uri) },
  )
}

fn com_retry(
  f: fn() -> Result(a, Erro),
  cb: Subject(CbMsg),
  tentativa: Int,
) -> Result(a, Erro) {
  case circuit_breaker.pode_executar(cb) {
    False -> Error(erro.ErroIA("serviço de IA temporariamente indisponível"))
    True ->
      case f() {
        Ok(r) -> {
          circuit_breaker.registrar_sucesso(cb)
          Ok(r)
        }
        Error(e) -> {
          circuit_breaker.registrar_falha(cb)
          case e_transiente(e) && tentativa < max_tentativas {
            True -> {
              process.sleep(espera_base_ms * pot2(tentativa))
              com_retry(f, cb, tentativa + 1)
            }
            False -> Error(e)
          }
        }
      }
  }
}

fn e_transiente(e: Erro) -> Bool {
  case e {
    erro.ErroIA(msg) ->
      string.contains(msg, "429")
      || string.contains(msg, "503")
      || string.contains(msg, "rate limit")
    erro.ErroComunicacao(_) -> True
    _ -> False
  }
}

fn pot2(n: Int) -> Int {
  case n {
    1 -> 2
    2 -> 4
    _ -> 8
  }
}
