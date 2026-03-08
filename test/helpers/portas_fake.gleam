import dominio/config
import dominio/erro.{type Erro}
import dominio/mensagem.{type Turno}
import gleam/erlang/process
import gleam/option.{None}
import portas/config_porta.{type ConfigPorta, ConfigPorta}
import portas/grupo_porta.{type GrupoPorta, GrupoPorta}
import portas/historico_porta.{type HistoricoPorta, HistoricoPorta}
import portas/ia_porta.{type IAPorta, IAPorta}
import portas/prompt_porta.{type PromptPorta, PromptPorta}
import portas/usuario_porta.{type UsuarioPorta, UsuarioPorta}
import portas/whatsapp_porta.{type WhatsappPorta, WhatsappPorta}
import shell/fila_midia
import shell/handler_mensagem.{type Portas, Portas}
import shell/metricas

// ---------------------------------------------------------------------------
// WhatsApp fake
// ---------------------------------------------------------------------------

pub fn whatsapp_ok() -> WhatsappPorta {
  WhatsappPorta(enviar: fn(_, _) { Ok(Nil) })
}

pub fn whatsapp_capturar(
  ref: process.Subject(#(String, String)),
) -> WhatsappPorta {
  WhatsappPorta(enviar: fn(chat_id, texto) {
    process.send(ref, #(chat_id, texto))
    Ok(Nil)
  })
}

pub fn whatsapp_erro(e: Erro) -> WhatsappPorta {
  WhatsappPorta(enviar: fn(_, _) { Error(e) })
}

// ---------------------------------------------------------------------------
// IA fake
// ---------------------------------------------------------------------------

pub fn ia_ok(resposta: String) -> IAPorta {
  IAPorta(
    gerar_texto: fn(_, _, _) { Ok(resposta) },
    processar_imagem: fn(_, _, _, _) { Ok(resposta) },
    processar_audio: fn(_, _, _) { Ok(resposta) },
    processar_video: fn(_, _, _) { Ok(resposta) },
    processar_documento: fn(_, _, _, _) { Ok(resposta) },
    fazer_upload_video: fn(_, _) { Ok("https://files.google.com/fake-uri") },
    aguardar_video_ativo: fn(_) { Ok(Nil) },
    deletar_arquivo: fn(_) { Ok(Nil) },
  )
}

pub fn ia_erro(e: Erro) -> IAPorta {
  IAPorta(
    gerar_texto: fn(_, _, _) { Error(e) },
    processar_imagem: fn(_, _, _, _) { Error(e) },
    processar_audio: fn(_, _, _) { Error(e) },
    processar_video: fn(_, _, _) { Error(e) },
    processar_documento: fn(_, _, _, _) { Error(e) },
    fazer_upload_video: fn(_, _) { Error(e) },
    aguardar_video_ativo: fn(_) { Error(e) },
    deletar_arquivo: fn(_) { Error(e) },
  )
}

pub fn ia_capturar_prompt(ref: process.Subject(String)) -> IAPorta {
  IAPorta(
    gerar_texto: fn(prompt, _, _) {
      process.send(ref, prompt)
      Ok("resposta fake")
    },
    processar_imagem: fn(_, _, prompt, _) {
      process.send(ref, prompt)
      Ok("descrição fake")
    },
    processar_audio: fn(_, _, _) { Ok("transcrição fake") },
    processar_video: fn(_, prompt, _) {
      process.send(ref, prompt)
      Ok("análise fake")
    },
    processar_documento: fn(_, _, prompt, _) {
      process.send(ref, prompt)
      Ok("extração fake")
    },
    fazer_upload_video: fn(_, _) { Ok("https://files.google.com/fake-uri") },
    aguardar_video_ativo: fn(_) { Ok(Nil) },
    deletar_arquivo: fn(_) { Ok(Nil) },
  )
}

// ---------------------------------------------------------------------------
// Config fake
// ---------------------------------------------------------------------------

pub fn config_ok(cfg) -> ConfigPorta {
  ConfigPorta(
    obter: fn(_) { Ok(cfg) },
    salvar: fn(_) { Ok(Nil) },
    resetar: fn(_) { Ok(Nil) },
  )
}

pub fn config_erro(e: Erro) -> ConfigPorta {
  ConfigPorta(
    obter: fn(_) { Error(e) },
    salvar: fn(_) { Error(e) },
    resetar: fn(_) { Error(e) },
  )
}

// Captura cada Config passado a `salvar` no Subject.
pub fn config_capturar(ref: process.Subject(config.Config)) -> ConfigPorta {
  ConfigPorta(
    obter: fn(chat_id) { Ok(config.padrao(chat_id)) },
    salvar: fn(cfg) {
      process.send(ref, cfg)
      Ok(Nil)
    },
    resetar: fn(_) { Ok(Nil) },
  )
}

// ---------------------------------------------------------------------------
// Histórico fake
// ---------------------------------------------------------------------------

pub fn historico_vazio() -> HistoricoPorta {
  historico_com([])
}

pub fn historico_com(turnos: List(Turno)) -> HistoricoPorta {
  HistoricoPorta(
    obter: fn(_) { Ok(turnos) },
    adicionar: fn(_, _) { Ok(Nil) },
    limpar: fn(_) { Ok(Nil) },
  )
}

pub fn historico_erro(e: Erro) -> HistoricoPorta {
  HistoricoPorta(
    obter: fn(_) { Error(e) },
    adicionar: fn(_, _) { Error(e) },
    limpar: fn(_) { Error(e) },
  )
}

// Captura cada chat_id passado a `limpar` no Subject.
pub fn historico_capturar_limpezas(
  ref: process.Subject(String),
) -> HistoricoPorta {
  HistoricoPorta(
    obter: fn(_) { Ok([]) },
    adicionar: fn(_, _) { Ok(Nil) },
    limpar: fn(chat_id) {
      process.send(ref, chat_id)
      Ok(Nil)
    },
  )
}

pub fn usuario_noop() -> UsuarioPorta {
  UsuarioPorta(
    registrar: fn(_cid) { Ok(Nil) },
    contar: fn() { Ok(0) },
    listar: fn() { Ok([]) },
  )
}

pub fn prompt_noop() -> PromptPorta {
  PromptPorta(
    definir: fn(_cid, _nome, _texto) { Ok(Nil) },
    obter: fn(_cid, _nome) { Ok(None) },
    listar: fn(_cid) { Ok([]) },
    excluir: fn(_cid, _nome) { Ok(Nil) },
  )
}

pub fn grupo_noop() -> GrupoPorta {
  GrupoPorta(registrar: fn(_cid, _nome) { Ok(Nil) }, listar: fn() { Ok([]) })
}

// ---------------------------------------------------------------------------
// Portas completas para testes de integração
// ---------------------------------------------------------------------------

pub fn portas_ok(cfg, resposta_ia: String) -> Portas {
  let fila = case fila_midia.iniciar_todas() {
    Ok(f) -> f
    Error(_) -> panic as "falha ao iniciar fila de mídia nos testes"
  }
  let met = case metricas.iniciar() {
    Ok(m) -> m
    Error(_) -> panic as "falha ao iniciar métricas nos testes"
  }
  Portas(
    whatsapp: whatsapp_ok(),
    ia: ia_ok(resposta_ia),
    config: config_ok(cfg),
    historico: historico_vazio(),
    fila: fila,
    prompts: prompt_noop(),
    metricas: met,
    usuarios: usuario_noop(),
    grupos: grupo_noop(),
  )
}
