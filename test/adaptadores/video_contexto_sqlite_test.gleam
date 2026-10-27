import adaptadores/video_contexto_sqlite
import dominio/video_contexto.{VideoContexto}
import gleam/option.{None, Some}
import gleeunit/should
import helpers/fixtures
import sqlight

pub fn obter_inexistente_retorna_none_test() {
  use conn <- sqlight.with_connection("file:ctx_none?mode=memory")
  let porta = video_contexto_sqlite.criar(conn)

  porta.obter(fixtures.id("chat_inexistente@c.us"))
  |> should.equal(Ok(None))
}

pub fn salvar_e_obter_test() {
  use conn <- sqlight.with_connection("file:ctx_salvar?mode=memory")
  let porta = video_contexto_sqlite.criar(conn)

  let ctx =
    VideoContexto(
      chat_id: fixtures.id("chat_123@c.us"),
      uri: "https://generativelanguage.googleapis.com/v1beta/files/vid123",
      perguntas_restantes: 2,
      criado_em: 1_700_000_000,
    )

  porta.salvar(ctx) |> should.be_ok

  let assert Ok(Some(salvo)) = porta.obter(fixtures.id("chat_123@c.us"))
  salvo.chat_id |> should.equal(fixtures.id("chat_123@c.us"))
  salvo.uri
  |> should.equal(
    "https://generativelanguage.googleapis.com/v1beta/files/vid123",
  )
  salvo.perguntas_restantes |> should.equal(2)
  salvo.criado_em |> should.equal(1_700_000_000)
}

pub fn salvar_substitui_existente_test() {
  use conn <- sqlight.with_connection("file:ctx_replace?mode=memory")
  let porta = video_contexto_sqlite.criar(conn)

  let ctx1 =
    VideoContexto(
      chat_id: fixtures.id("chat_123@c.us"),
      uri: "https://files/vid1",
      perguntas_restantes: 1,
      criado_em: 1000,
    )
  let ctx2 =
    VideoContexto(
      chat_id: fixtures.id("chat_123@c.us"),
      uri: "https://files/vid2",
      perguntas_restantes: 2,
      criado_em: 2000,
    )

  porta.salvar(ctx1) |> should.be_ok
  porta.salvar(ctx2) |> should.be_ok

  let assert Ok(Some(salvo)) = porta.obter(fixtures.id("chat_123@c.us"))
  salvo.uri |> should.equal("https://files/vid2")
  salvo.perguntas_restantes |> should.equal(2)
  salvo.criado_em |> should.equal(2000)
}

pub fn decrementar_perguntas_test() {
  use conn <- sqlight.with_connection("file:ctx_dec?mode=memory")
  let porta = video_contexto_sqlite.criar(conn)

  let ctx =
    VideoContexto(
      chat_id: fixtures.id("chat_123@c.us"),
      uri: "https://files/vid1",
      perguntas_restantes: 2,
      criado_em: 1000,
    )
  porta.salvar(ctx) |> should.be_ok

  let assert Ok(dec1) =
    porta.decrementar_perguntas(fixtures.id("chat_123@c.us"))
  dec1 |> should.equal(1)

  let assert Ok(dec2) =
    porta.decrementar_perguntas(fixtures.id("chat_123@c.us"))
  dec2 |> should.equal(0)

  // Decrementar além de 0 continua 0
  let assert Ok(dec3) =
    porta.decrementar_perguntas(fixtures.id("chat_123@c.us"))
  dec3 |> should.equal(0)

  // Decrementar em chat inexistente retorna Ok(0)
  porta.decrementar_perguntas(fixtures.id("chat_inexistente@c.us"))
  |> should.equal(Ok(0))
}

pub fn remover_test() {
  use conn <- sqlight.with_connection("file:ctx_remover?mode=memory")
  let porta = video_contexto_sqlite.criar(conn)

  let ctx =
    VideoContexto(
      chat_id: fixtures.id("chat_123@c.us"),
      uri: "https://files/vid1",
      perguntas_restantes: 2,
      criado_em: 1000,
    )
  porta.salvar(ctx) |> should.be_ok

  porta.remover(fixtures.id("chat_123@c.us"))
  |> should.equal(Ok(Some("https://files/vid1")))

  porta.obter(fixtures.id("chat_123@c.us")) |> should.equal(Ok(None))

  porta.remover(fixtures.id("chat_123@c.us"))
  |> should.equal(Ok(None))
}

pub fn limpar_expirados_test() {
  use conn <- sqlight.with_connection("file:ctx_limpar?mode=memory")
  let porta = video_contexto_sqlite.criar(conn)

  let antigo1 =
    VideoContexto(
      chat_id: fixtures.id("chat_antigo_1@c.us"),
      uri: "https://files/antigo1",
      perguntas_restantes: 2,
      criado_em: 100,
    )
  let antigo2 =
    VideoContexto(
      chat_id: fixtures.id("chat_antigo_2@c.us"),
      uri: "https://files/antigo2",
      perguntas_restantes: 1,
      criado_em: 200,
    )
  let recente =
    VideoContexto(
      chat_id: fixtures.id("chat_recente@c.us"),
      uri: "https://files/recente",
      perguntas_restantes: 2,
      criado_em: 500,
    )

  porta.salvar(antigo1) |> should.be_ok
  porta.salvar(antigo2) |> should.be_ok
  porta.salvar(recente) |> should.be_ok

  // Limpa antes de 300: antigo1 e antigo2 devem ser removidos e suas URIs retornadas
  let assert Ok(uris_removidas) = porta.limpar_expirados(300)
  uris_removidas
  |> should.equal(["https://files/antigo1", "https://files/antigo2"])

  porta.obter(fixtures.id("chat_antigo_1@c.us")) |> should.equal(Ok(None))
  porta.obter(fixtures.id("chat_antigo_2@c.us")) |> should.equal(Ok(None))
  porta.obter(fixtures.id("chat_recente@c.us")) |> should.not_equal(Ok(None))
}
