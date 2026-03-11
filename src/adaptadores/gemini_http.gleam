// Adaptador HTTP para Google Gemini API.
// Implementa IAPorta.

import dominio/erro.{type Erro}
import dominio/mensagem.{type Turno, TurnoAssistente, TurnoUsuario}
import gleam/bit_array
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import portas/ia_porta.{type IAPorta, IAPorta}

const base_url = "https://generativelanguage.googleapis.com/v1beta/models/"

pub fn criar(api_key: String) -> IAPorta {
  IAPorta(
    gerar_texto: fn(prompt, historico, modelo) {
      gerar_texto(api_key, prompt, historico, modelo)
    },
    processar_imagem: fn(dados, mime, prompt, modelo) {
      processar_inline(api_key, dados, mime, prompt, modelo)
    },
    processar_audio: fn(dados, mime, modelo) {
      processar_inline(
        api_key,
        dados,
        mime,
        "Transcreva e resuma este áudio.",
        modelo,
      )
    },
    processar_video: fn(uri, prompt, modelo) {
      processar_video(api_key, uri, prompt, modelo)
    },
    processar_documento: fn(dados, mime, prompt, modelo) {
      processar_inline(api_key, dados, mime, prompt, modelo)
    },
    fazer_upload_video: fn(caminho, mime) {
      fazer_upload_video(api_key, caminho, mime)
    },
    aguardar_video_ativo: fn(uri) { aguardar_video_ativo(api_key, uri) },
    deletar_arquivo: fn(uri) { deletar_arquivo(api_key, uri) },
  )
}

// ---------------------------------------------------------------------------
// Texto
// ---------------------------------------------------------------------------

fn gerar_texto(
  api_key: String,
  prompt: String,
  historico: List(Turno),
  modelo: String,
) -> Result(String, Erro) {
  let contents = historico_para_contents(historico, prompt)
  let body =
    json.object([#("contents", json.preprocessed_array(contents))])
    |> json.to_string

  use resp_body <- result.try(post_gemini(api_key, modelo, body))
  extrair_texto_resposta(resp_body)
}

fn historico_para_contents(
  historico: List(Turno),
  prompt_atual: String,
) -> List(json.Json) {
  let turnos_json =
    list.map(historico, fn(turno) {
      case turno {
        TurnoUsuario(c) -> content_json("user", c)
        TurnoAssistente(c) -> content_json("model", c)
      }
    })
  list.append(turnos_json, [content_json("user", prompt_atual)])
}

fn content_json(role: String, text: String) -> json.Json {
  json.object([
    #("role", json.string(role)),
    #(
      "parts",
      json.preprocessed_array([json.object([#("text", json.string(text))])]),
    ),
  ])
}

// ---------------------------------------------------------------------------
// Mídia inline (imagem, áudio, documento)
// ---------------------------------------------------------------------------

fn processar_inline(
  api_key: String,
  dados: BitArray,
  mime: String,
  prompt: String,
  modelo: String,
) -> Result(String, Erro) {
  // Gemini não aceita parâmetros de codec no MIME type (ex: "audio/ogg; codecs=opus").
  let mime = case string.split_once(mime, ";") {
    Ok(#(base, _)) -> string.trim(base)
    Error(_) -> mime
  }
  let b64 = bit_array.base64_encode(dados, True)
  let parts =
    json.preprocessed_array([
      json.object([#("text", json.string(prompt))]),
      json.object([
        #(
          "inline_data",
          json.object([
            #("mime_type", json.string(mime)),
            #("data", json.string(b64)),
          ]),
        ),
      ]),
    ])

  let body =
    json.object([
      #(
        "contents",
        json.preprocessed_array([json.object([#("parts", parts)])]),
      ),
    ])
    |> json.to_string

  use resp_body <- result.try(post_gemini(api_key, modelo, body))
  extrair_texto_resposta(resp_body)
}

// ---------------------------------------------------------------------------
// Vídeo (via File API URI)
// ---------------------------------------------------------------------------

fn processar_video(
  api_key: String,
  uri: String,
  prompt: String,
  modelo: String,
) -> Result(String, Erro) {
  let parts =
    json.preprocessed_array([
      json.object([#("text", json.string(prompt))]),
      json.object([
        #("file_data", json.object([#("file_uri", json.string(uri))])),
      ]),
    ])

  let body =
    json.object([
      #(
        "contents",
        json.preprocessed_array([json.object([#("parts", parts)])]),
      ),
    ])
    |> json.to_string

  use resp_body <- result.try(post_gemini(api_key, modelo, body))
  extrair_texto_resposta(resp_body)
}

// ---------------------------------------------------------------------------
// File API — upload, poll, delete
// ---------------------------------------------------------------------------

fn fazer_upload_video(
  api_key: String,
  caminho: String,
  mime: String,
) -> Result(String, Erro) {
  // Gemini File API exige multipart binary — usamos FFI para enviar o arquivo diretamente.
  upload_file_ffi(api_key, caminho, mime)
  |> result.map_error(fn(msg) { erro.ErroUpload(msg) })
  |> result.try(fn(body) {
    extrair_uri_arquivo(body)
    |> result.map_error(fn(_) { erro.ErroUpload("uri ausente na resposta") })
  })
}

// Polling com até 20 tentativas (3s cada = 60s máximo).
fn aguardar_video_ativo(api_key: String, uri: String) -> Result(Nil, Erro) {
  aguardar_loop(api_key, uri, 20)
}

fn aguardar_loop(
  api_key: String,
  uri: String,
  restantes: Int,
) -> Result(Nil, Erro) {
  case restantes {
    0 ->
      Error(erro.ErroProcessamentoVideo("timeout aguardando vídeo ficar ativo"))
    n -> {
      let url = uri <> "?key=" <> api_key
      use req <- result.try(
        request.to(url)
        |> result.map_error(fn(_) {
          erro.ErroComunicacao("url de status inválida")
        }),
      )
      use resp <- result.try(
        httpc.send(req)
        |> result.map_error(fn(_) {
          erro.ErroProcessamentoVideo("falha ao verificar status do vídeo")
        }),
      )
      case resp.status {
        200 ->
          case string.contains(resp.body, "\"ACTIVE\"") {
            True -> Ok(Nil)
            False -> {
              process.sleep(3000)
              aguardar_loop(api_key, uri, n - 1)
            }
          }
        // 5xx são transitórios — retentar
        s if s >= 500 -> {
          process.sleep(3000)
          aguardar_loop(api_key, uri, n - 1)
        }
        status ->
          Error(
            erro.ErroProcessamentoVideo(
              "status inesperado " <> int.to_string(status),
            ),
          )
      }
    }
  }
}

fn deletar_arquivo(api_key: String, uri: String) -> Result(Nil, Erro) {
  let url = uri <> "?key=" <> api_key
  use req <- result.try(
    request.to(url)
    |> result.map_error(fn(_) { erro.ErroComunicacao("url de deleção inválida") }),
  )

  let req = req |> request.set_method(http.Delete)
  let _ = httpc.send(req)
  Ok(Nil)
}

// ---------------------------------------------------------------------------
// HTTP helper
// ---------------------------------------------------------------------------

fn post_gemini(
  api_key: String,
  modelo: String,
  body: String,
) -> Result(String, Erro) {
  let url = base_url <> modelo <> ":generateContent?key=" <> api_key

  use req <- result.try(
    request.to(url)
    |> result.map_error(fn(_) { erro.ErroComunicacao("url gemini inválida") }),
  )

  let req =
    req
    |> request.set_method(http.Post)
    |> request.set_header("content-type", "application/json")
    |> request.set_body(body)

  use resp <- result.try(
    httpc.send(req)
    |> result.map_error(fn(_) { erro.ErroIA("falha ao chamar Gemini") }),
  )

  case resp.status {
    200 -> Ok(resp.body)
    429 -> Error(erro.ErroIA("rate limit Gemini"))
    status ->
      Error(erro.ErroIA("Gemini retornou status " <> int.to_string(status)))
  }
}

// ---------------------------------------------------------------------------
// Decodificação de respostas JSON (gleam_json 3.x — json.parse + decode)
// ---------------------------------------------------------------------------

fn extrair_texto_resposta(json_str: String) -> Result(String, Erro) {
  // {"candidates":[{"content":{"parts":[{"text":"..."}]}}]}
  let decoder =
    decode.at(["candidates"], decode.list(
      decode.at(["content"],
        decode.at(["parts"], decode.list(decode.at(["text"], decode.string))),
      ),
    ))

  case json.parse(json_str, decoder) {
    Ok([[text, ..], ..]) -> Ok(text)
    _ -> Error(erro.ErroIA("formato de resposta Gemini inesperado"))
  }
}

fn extrair_uri_arquivo(json_str: String) -> Result(String, Nil) {
  let decoder = decode.at(["file"], decode.at(["uri"], decode.string))
  json.parse(json_str, decoder)
  |> result.map_error(fn(_) { Nil })
}

// ---------------------------------------------------------------------------
// FFI
// ---------------------------------------------------------------------------

@external(erlang, "amelie_gleam_ffi", "upload_file")
fn upload_file_ffi(
  api_key: String,
  caminho: String,
  mime: String,
) -> Result(String, String)
