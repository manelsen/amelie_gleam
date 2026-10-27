// Porta para as operações da ponte whatsmeow além do envio de mensagens:
// estado da sessão, pareamento, reset e busca de páginas com DNS fixado.

import dominio/erro.{type Erro}

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
