// Porta para a saúde do armazenamento: o healthcheck pergunta se o banco
// responde sem conhecer o driver.

pub type ArmazenamentoPorta {
  ArmazenamentoPorta(
    // verificar() -> Ok, ou a mensagem de erro do banco
    verificar: fn() -> Result(Nil, String),
  )
}
