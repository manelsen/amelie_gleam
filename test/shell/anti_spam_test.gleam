// test/shell/anti_spam_test.gleam
// Testes unitários para o ator OTP de anti_spam.

import core/anti_spam as core_anti_spam
import dominio/mensagem.{Texto}
import gleam/erlang/process
import gleam/option.{None, Some}
import gleeunit/should
import helpers/fixtures
import shell/anti_spam

pub fn anti_spam_actor_inicializacao_e_verificacao_test() {
  let assert Ok(actor) = anti_spam.iniciar(Some(fixtures.id("tg:123")))

  // Chat comum tem permissão inicial
  let dec =
    anti_spam.verificar(
      actor,
      fixtures.id("user_456@c.us"),
      fixtures.id("user_456@c.us"),
      Texto("Olá"),
    )
  dec |> should.equal(core_anti_spam.Permitido)

  // Admin sempre permitido
  let dec_admin =
    anti_spam.verificar(
      actor,
      fixtures.id("tg:123"),
      fixtures.id("tg:123"),
      Texto("Status"),
    )
  dec_admin |> should.equal(core_anti_spam.Permitido)
}

pub fn anti_spam_actor_desbloquear_e_contar_test() {
  let assert Ok(actor) = anti_spam.iniciar(None)

  // Inicialmente 0 silenciados
  anti_spam.contar_silenciados(actor) |> should.equal(0)

  // Desbloquear chat inexistente retorna falso
  anti_spam.desbloquear(actor, "inexistente") |> should.be_false
}

pub fn anti_spam_actor_limpeza_periodica_test() {
  let assert Ok(actor) = anti_spam.iniciar(None)

  process.send(actor, anti_spam.LimpezaPeriodica(1_000_000))
  // Ator continua respondendo normalmente
  anti_spam.contar_silenciados(actor) |> should.equal(0)
}
