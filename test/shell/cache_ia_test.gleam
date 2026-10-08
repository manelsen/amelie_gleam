import dominio/mensagem.{TurnoAssistente, TurnoUsuario}
import gleeunit/should
import helpers/portas_fake
import portas/ia_porta
import shell/cache_ia
import shell/circuit_breaker
import shell/ia_resiliente

pub fn historico_completo_faz_parte_da_chave_test() {
  let a = [TurnoUsuario("segredo A"), TurnoUsuario("cauda comum")]
  let b = [TurnoUsuario("segredo B"), TurnoUsuario("cauda comum")]
  cache_ia.chave("mesmo prompt truncado", a, "modelo")
  |> should.not_equal(cache_ia.chave("mesmo prompt truncado", b, "modelo"))
}

pub fn papeis_e_delimitadores_nao_colidem_test() {
  cache_ia.chave("a|b", [], "c")
  |> should.not_equal(cache_ia.chave("a", [], "b|c"))
  cache_ia.chave("a", [TurnoUsuario("b")], "c")
  |> should.not_equal(cache_ia.chave("a", [TurnoAssistente("b")], "c"))
}

pub fn argumentos_identicos_mantem_a_chave_test() {
  cache_ia.chave("a", [TurnoUsuario("b")], "c")
  |> should.equal(cache_ia.chave("a", [TurnoUsuario("b")], "c"))
}

pub fn resposta_de_outra_conversa_nao_e_reutilizada_test() {
  let assert Ok(cache) = cache_ia.iniciar()
  let assert Ok(circuito) = circuit_breaker.iniciar()
  let porta =
    ia_porta.IAPorta(
      ..portas_fake.ia_ok("unused"),
      gerar_texto: fn(_, historico, _) {
        case historico {
          [TurnoUsuario(privado), ..] -> Ok(privado)
          _ -> Ok("empty")
        }
      },
    )
  let resiliente = ia_resiliente.envolver(porta, circuito, cache)
  resiliente.gerar_texto("mesmo prompt", [TurnoUsuario("privado A")], "modelo")
  |> should.equal(Ok("privado A"))
  resiliente.gerar_texto("mesmo prompt", [TurnoUsuario("privado B")], "modelo")
  |> should.equal(Ok("privado B"))
}
