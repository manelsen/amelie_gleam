/// Restaura o ambiente mesmo se o teste falhar. Usar em testes sequenciais.
@external(erlang, "amelie_security_tests", "with_env")
pub fn com_variavel(nome: String, valor: String, executar: fn() -> a) -> a
