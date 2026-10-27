// Porta para as operações da ponte whatsmeow além do envio de mensagens:
// estado da sessão, pareamento, reset e busca de páginas com DNS fixado.

import dominio/erro.{type Erro}

/// Cabeçalho com o segredo compartilhado (BRIDGE_TOKEN), nos dois sentidos:
/// Gleam → ponte e ponte → webhooks do Gleam.
pub const cabecalho_token = "x-amelie-bridge-token"

pub type StatusPonte {
  StatusPonte(conectado: Bool, logado: Bool)
}

pub type PontePorta {
  PontePorta(
    checar_status: fn() -> Result(StatusPonte, Erro),
    // pedir_codigo_pareamento(telefone) -> código ou motivo da recusa
    pedir_codigo_pareamento: fn(String) -> Result(String, String),
    // resetar_sessao(telefone); telefone vazio só desconecta
    resetar_sessao: fn(String) -> Result(Nil, String),
    buscar_pagina: fn(String) -> Result(String, Erro),
  )
}
