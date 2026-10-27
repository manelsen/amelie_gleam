// Porta para gerenciamento de prompts nomeados por chat.

import dominio/erro.{type Erro}
import dominio/id_chat.{type IdChat}
import gleam/option.{type Option}

pub type PromptPorta {
  PromptPorta(
    definir: fn(IdChat, String, String) -> Result(Nil, Erro),
    obter: fn(IdChat, String) -> Result(Option(String), Erro),
    listar: fn(IdChat) -> Result(List(String), Erro),
    excluir: fn(IdChat, String) -> Result(Nil, Erro),
  )
}
