// test/adaptadores/spammer_sqlite_test.gleam
// Testes para a persistência SQLite de incidentes de spam.

import adaptadores/spammer_sqlite
import gleeunit/should
import helpers/fixtures
import sqlight

pub fn registrar_e_contar_test() {
  use conn <- sqlight.with_connection("file:spammer_reg_test?mode=memory")
  let porta = spammer_sqlite.criar(conn)

  // Inicialmente vazio
  porta.contar() |> should.equal(Ok(0))

  // Registra primeiro incidente (aviso)
  porta.registrar(
    fixtures.id("5511999998888@s.whatsapp.net"),
    fixtures.id("5511999998888@s.whatsapp.net"),
    "5511999998888",
    "muitas mensagens seguidas",
    1,
  )
  |> should.be_ok

  porta.contar() |> should.equal(Ok(1))

  // Registra segundo incidente (bloqueio strike 3)
  porta.registrar(
    fixtures.id("5511999998888@s.whatsapp.net"),
    fixtures.id("5511999998888@s.whatsapp.net"),
    "5511999998888",
    "flood volumétrico contínuo",
    3,
  )
  |> should.be_ok

  porta.contar() |> should.equal(Ok(2))
}

pub fn listar_recentes_test() {
  use conn <- sqlight.with_connection("file:spammer_rec_test?mode=memory")
  let porta = spammer_sqlite.criar(conn)

  let _ =
    porta.registrar(
      fixtures.id("chat1@c.us"),
      fixtures.id("user1@c.us"),
      "5511911111111",
      "motivo 1",
      1,
    )
  let _ =
    porta.registrar(
      fixtures.id("chat2@c.us"),
      fixtures.id("user2@c.us"),
      "5521922222222",
      "motivo 2",
      2,
    )

  let assert Ok(recentes) = porta.listar_recentes(10)
  recentes |> should.not_equal([])
  let assert [primeiro, segundo] = recentes

  primeiro.telefone |> should.equal("5521922222222")
  primeiro.strike |> should.equal(2)
  primeiro.motivo |> should.equal("motivo 2")

  segundo.telefone |> should.equal("5511911111111")
  segundo.strike |> should.equal(1)
}

pub fn listar_top_test() {
  use conn <- sqlight.with_connection("file:spammer_top_test?mode=memory")
  let porta = spammer_sqlite.criar(conn)

  // Telefone A tem 3 incidentes
  let _ =
    porta.registrar(
      fixtures.id("c1@c.us"),
      fixtures.id("u1@c.us"),
      "5511AAAA",
      "flood",
      1,
    )
  let _ =
    porta.registrar(
      fixtures.id("c1@c.us"),
      fixtures.id("u1@c.us"),
      "5511AAAA",
      "flood",
      2,
    )
  let _ =
    porta.registrar(
      fixtures.id("c1@c.us"),
      fixtures.id("u1@c.us"),
      "5511AAAA",
      "flood",
      3,
    )

  // Telefone B tem 1 incidente
  let _ =
    porta.registrar(
      fixtures.id("c2@c.us"),
      fixtures.id("u2@c.us"),
      "5521BBBB",
      "flood",
      1,
    )

  let assert Ok(top) = porta.listar_top(5)
  let assert [top1, top2] = top

  top1.telefone |> should.equal("5511AAAA")
  top1.total_incidentes |> should.equal(3)
  top1.ultimo_strike |> should.equal(3)

  top2.telefone |> should.equal("5521BBBB")
  top2.total_incidentes |> should.equal(1)
  top2.ultimo_strike |> should.equal(1)
}
