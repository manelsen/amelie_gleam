import dominio/config.{type Config}
import dominio/erro.{type Erro}

pub type ConfigPorta {
  ConfigPorta(
    obter: fn(String) -> Result(Config, Erro),
    salvar: fn(Config) -> Result(Nil, Erro),
    resetar: fn(String) -> Result(Nil, Erro),
  )
}
