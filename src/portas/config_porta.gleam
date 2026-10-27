import dominio/config.{type Config}
import dominio/erro.{type Erro}
import dominio/id_chat.{type IdChat}

pub type ConfigPorta {
  ConfigPorta(
    obter: fn(IdChat) -> Result(Config, Erro),
    salvar: fn(Config) -> Result(Nil, Erro),
    resetar: fn(IdChat) -> Result(Nil, Erro),
  )
}
