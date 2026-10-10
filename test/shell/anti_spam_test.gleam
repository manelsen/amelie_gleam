// test/shell/anti_spam_test.gleam
// Testes unitários para o ator OTP de anti_spam.

import core/anti_spam as core_anti_spam
import dominio/mensagem.{Texto}
import gleam/erlang/process
import gleeunit/should
import shell/anti_spam

pub fn anti_spam_actor_inicializacao_e_verificacao_test() {
  let assert Ok(actor) = anti_spam.iniciar("admin_123")

  // Chat comum tem permissão inicial
  let dec = anti_spam.verificar(actor, "user_456", "user_456", Texto("Olá"))
  dec |> should.equal(core_anti_spam.Permitido)

  // Admin sempre permitido
  let dec_admin =
    anti_spam.verificar(actor, "tg:admin_123", "tg:admin_123", Texto("Status"))
  dec_admin |> should.equal(core_anti_spam.Permitido)
}

pub fn anti_spam_actor_desbloquear_e_contar_test() {
  let assert Ok(actor) = anti_spam.iniciar("")

  // Inicialmente 0 silenciados
  anti_spam.contar_silenciados(actor) |> should.equal(0)

  // Desbloquear chat inexistente retorna falso
  anti_spam.desbloquear(actor, "inexistente") |> should.be_false
}

pub fn anti_spam_actor_limpeza_periodica_test() {
  let assert Ok(actor) = anti_spam.iniciar("")

  process.send(actor, anti_spam.LimpezaPeriodica(1_000_000))
  // Ator continua respondendo normalmente
  anti_spam.contar_silenciados(actor) |> should.equal(0)
}
