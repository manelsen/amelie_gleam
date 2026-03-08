// Porta para gerenciamento de prompts nomeados por chat.

import dominio/erro.{type Erro}
import gleam/option.{type Option}

pub type PromptPorta {
  PromptPorta(
    definir: fn(String, String, String) -> Result(Nil, Erro),
    obter: fn(String, String) -> Result(Option(String), Erro),
    listar: fn(String) -> Result(List(String), Erro),
    excluir: fn(String, String) -> Result(Nil, Erro),
  )
}
