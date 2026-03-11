// Adaptador HTTP para OpenRouter API.
// Implementa IAPorta.

import dominio/erro.{type Erro}
import dominio/mensagem.{type Turno, TurnoAssistente, TurnoUsuario}
import gleam/bit_array
import gleam/dynamic/decode
import gleam/http
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/json
import gleam/list
import gleam/result
import portas/ia_porta.{type IAPorta, IAPorta}

const base_url = "https://openrouter.ai/api/v1/chat/completions"

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

fn gerar_texto(
  api_key: String,
  prompt: String,
  historico: List(Turno),
  modelo: String,
) -> Result(String, Erro) {
  let messages = historico_para_messages(historico, prompt)
  let body =
    json.object([
      #("model", json.string(modelo)),
      #("messages", json.preprocessed_array(messages)),
    ])
    |> json.to_string

  use resp_body <- result.try(post_openrouter(api_key, body))
  extrair_texto_resposta(resp_body)
}

fn historico_para_messages(
  historico: List(Turno),
  prompt_atual: String,
) -> List(json.Json) {
  let turnos_json =
    list.map(historico, fn(turno) {
      case turno {
        TurnoUsuario(c) -> message_json("user", c)
        TurnoAssistente(c) -> message_json("assistant", c)
      }
    })
  list.append(turnos_json, [message_json("user", prompt_atual)])
}

fn message_json(role: String, text: String) -> json.Json {
  json.object([
    #("role", json.string(role)),
    #("content", json.string(text)),
  ])
}

fn processar_inline(
  api_key: String,
  dados: BitArray,
  mime: String,
  prompt: String,
  modelo: String,
) -> Result(String, Erro) {
  let b64 = bit_array.base64_encode(dados, True)

  let content =
    json.object([
      #("type", json.string("text")),
      #("text", json.string(prompt)),
    ])

  let image =
    json.object([
      #("type", json.string("image_url")),
      #(
        "image_url",
        json.object([
          #("url", json.string("data:" <> mime <> ";base64," <> b64)),
        ]),
      ),
    ])

  let messages =
    json.preprocessed_array([
      json.object([
        #("role", json.string("user")),
        #("content", json.preprocessed_array([content, image])),
      ]),
    ])

  let body =
    json.object([
      #("model", json.string(modelo)),
      #("messages", messages),
    ])
    |> json.to_string

  use resp_body <- result.try(post_openrouter(api_key, body))
  extrair_texto_resposta(resp_body)
}

fn processar_video(
  api_key: String,
  uri: String,
  prompt: String,
  modelo: String,
) -> Result(String, Erro) {
  let content =
    json.object([
      #("type", json.string("text")),
      #("text", json.string(prompt)),
    ])

  let video =
    json.object([
      #("type", json.string("image_url")),
      #("image_url", json.object([#("url", json.string(uri))])),
    ])

  let messages =
    json.preprocessed_array([
      json.object([
        #("role", json.string("user")),
        #("content", json.preprocessed_array([content, video])),
      ]),
    ])

  let body =
    json.object([
      #("model", json.string(modelo)),
      #("messages", messages),
    ])
    |> json.to_string

  use resp_body <- result.try(post_openrouter(api_key, body))
  extrair_texto_resposta(resp_body)
}

fn fazer_upload_video(
  _api_key: String,
  _caminho: String,
  _mime: String,
) -> Result(String, Erro) {
  Error(erro.ErroUpload("OpenRouter não suporta upload direto de vídeo"))
}

fn aguardar_video_ativo(_api_key: String, _uri: String) -> Result(Nil, Erro) {
  Ok(Nil)
}

fn deletar_arquivo(_api_key: String, _uri: String) -> Result(Nil, Erro) {
  Ok(Nil)
}

fn post_openrouter(api_key: String, body: String) -> Result(String, Erro) {
  use req <- result.try(
    request.to(base_url)
    |> result.map_error(fn(_) {
      erro.ErroComunicacao("url openrouter inválida")
    }),
  )

  let req =
    req
    |> request.set_method(http.Post)
    |> request.set_header("content-type", "application/json")
    |> request.set_header("Authorization", "Bearer " <> api_key)
    |> request.set_body(body)

  use resp <- result.try(
    httpc.send(req)
    |> result.map_error(fn(_) { erro.ErroIA("falha ao chamar OpenRouter") }),
  )

  case resp.status {
    200 -> Ok(resp.body)
    429 -> Error(erro.ErroIA("rate limit OpenRouter"))
    status ->
      Error(erro.ErroIA("OpenRouter retornou status " <> int.to_string(status)))
  }
}

fn extrair_texto_resposta(json_str: String) -> Result(String, Erro) {
  let decoder =
    decode.at(
      ["choices"],
      decode.list(decode.at(["message"], decode.at(["content"], decode.string))),
    )

  case json.parse(json_str, decoder) {
    Ok([text, ..]) -> Ok(text)
    _ -> Error(erro.ErroIA("formato de resposta OpenRouter inesperado"))
  }
}
