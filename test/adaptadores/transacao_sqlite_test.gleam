import adaptadores/transacao_sqlite
import dominio/id_chat
import dominio/transacao.{Entregue, Pendente, Transacao}
import gleam/dynamic/decode
import gleam/option.{None, Some}
import gleeunit/should
import helpers/fixtures
import sqlight

pub fn limpar_antigas_remove_transacoes_e_mensagens_expiradas_test() {
  use conn <- sqlight.with_connection("file:transacao_limpeza?mode=memory")
  let porta = transacao_sqlite.criar(conn)

  // 1. Cria transação entregue antiga (8 dias atrás)
  let _ =
    sqlight.exec(
      "INSERT INTO transacoes (chat_id, remetente, tipo, conteudo, status, criado_em)
       VALUES ('chat1@c.us', 'user1', 'texto', 'msg antiga', 'entregue', unixepoch() - 8 * 24 * 3600);",
      conn,
    )

  // 2. Cria transação entregue recente
  let tx_recente =
    Transacao(
      id: None,
      chat_id: fixtures.id("chat1@c.us"),
      remetente: "user1",
      tipo: "texto",
      conteudo: "msg recente",
      status: Entregue,
      criado_em: 0,
      atualizado_em: None,
      tentativas: 0,
      erro: None,
    )
  let assert Ok(tx_salva) = porta.registrar(tx_recente)
  let assert Some(id_recente) = tx_salva.id
  let assert Ok(Nil) = porta.marcar_entregue(id_recente)

  // 3. Cria transação pendente antiga (não deve ser removida mesmo se antiga!)
  let _ =
    sqlight.exec(
      "INSERT INTO transacoes (chat_id, remetente, tipo, conteudo, status, criado_em)
       VALUES ('chat1@c.us', 'user1', 'texto', 'msg pendente antiga', 'pendente', unixepoch() - 8 * 24 * 3600);",
      conn,
    )

  // 4. Insere mensagem recebida antiga e mensagem recebida recente
  let _ =
    sqlight.exec(
      "INSERT INTO mensagens_recebidas (message_id, recebido_em)
       VALUES ('mid_antigo', unixepoch() - 8 * 24 * 3600);",
      conn,
    )
  let assert Ok(Nil) =
    porta.marcar_recebida(fixtures.id("chat1@c.us"), "mid_recente")

  // 5. Executa limpar_antigas
  let assert Ok(Nil) = porta.limpar_antigas()

  // 6. Verifica deduplicação: mid_antigo foi apagado, mid_recente preservado
  porta.foi_recebida(fixtures.id("chat1@c.us"), "mid_antigo")
  |> should.equal(Ok(False))

  porta.foi_recebida(fixtures.id("chat1@c.us"), "mid_recente")
  |> should.equal(Ok(True))

  // 7. Verifica que a transação pendente continua existindo
  let assert Ok(pendentes) = porta.obter_pendentes()
  should.be_true(case pendentes {
    [tx] -> tx.conteudo == "msg pendente antiga" && tx.status == Pendente
    _ -> False
  })
}

pub fn sqlite_pragmas_concorrencia_test() {
  use conn <- sqlight.with_connection("file:test_pragmas?mode=memory")
  sqlight.exec("PRAGMA journal_mode = WAL;", conn)
  |> should.equal(Ok(Nil))

  sqlight.exec("PRAGMA busy_timeout = 5000;", conn)
  |> should.equal(Ok(Nil))

  sqlight.exec("PRAGMA synchronous = NORMAL;", conn)
  |> should.equal(Ok(Nil))
}

pub fn registrar_com_insert_falhando_retorna_erro_test() {
  use conn <- sqlight.with_connection("file:transacao_insert_falha?mode=memory")
  let porta = transacao_sqlite.criar(conn)
  let tx =
    Transacao(
      id: None,
      chat_id: fixtures.id("chat1@c.us"),
      remetente: "user1",
      tipo: "texto",
      conteudo: "primeira",
      status: Pendente,
      criado_em: 0,
      atualizado_em: None,
      tentativas: 0,
      erro: None,
    )
  let assert Ok(primeira) = porta.registrar(tx)
  primeira.id |> should.be_some

  // Sem a tabela, o INSERT falha; antes, last_insert_rowid() devolvia o id
  // da primeira transação como se a nova tivesse sido gravada.
  let assert Ok(Nil) = sqlight.exec("DROP TABLE transacoes", conn)
  porta.registrar(Transacao(..tx, conteudo: "segunda"))
  |> should.be_error
}

pub fn dedup_telegram_separa_chats_com_mesmo_message_id_test() {
  use conn <- sqlight.with_connection("file:dedup_telegram?mode=memory")
  let porta = transacao_sqlite.criar(conn)
  let chat_a = id_chat.telegram(111)
  let chat_b = id_chat.telegram(222)

  let assert Ok(Nil) = porta.marcar_recebida(chat_a, "42")

  porta.foi_recebida(chat_a, "42") |> should.equal(Ok(True))
  // No Telegram o message_id é contador por chat: a 42 do outro chat é nova.
  porta.foi_recebida(chat_b, "42") |> should.equal(Ok(False))
}

pub fn dedup_whatsapp_mantem_chave_antiga_test() {
  use conn <- sqlight.with_connection("file:dedup_whatsapp?mode=memory")
  let porta = transacao_sqlite.criar(conn)
  // Registro gravado antes desta mudança, só com o message_id.
  let assert Ok(Nil) =
    sqlight.exec(
      "INSERT INTO mensagens_recebidas (message_id) VALUES ('3EB0ABC')",
      conn,
    )

  porta.foi_recebida(fixtures.id("5531999990000@s.whatsapp.net"), "3EB0ABC")
  |> should.equal(Ok(True))
}

fn tx_nova(conteudo: String) -> transacao.Transacao {
  transacao.novo(fixtures.id("chat1@c.us"), transacao.RespostaIA, conteudo)
}

pub fn pendentes_ignora_envio_em_voo_test() {
  use conn <- sqlight.with_connection("file:transacao_em_voo?mode=memory")
  let porta = transacao_sqlite.criar(conn)

  // Recém-registrada e sem falha: o envio ainda está em andamento.
  let assert Ok(tx) = porta.registrar(tx_nova("em voo"))
  porta.obter_pendentes() |> should.equal(Ok([]))

  // Depois da primeira falha, é da fila offline.
  let assert Some(id) = tx.id
  let assert Ok(Nil) = porta.atualizar_erro(id, "offline", 1)
  let assert Ok([pendente]) = porta.obter_pendentes()
  pendente.conteudo |> should.equal("em voo")
}

pub fn pendentes_pula_e_descarta_linha_com_chat_ilegivel_test() {
  use conn <- sqlight.with_connection("file:transacao_ilegivel?mode=memory")
  let porta = transacao_sqlite.criar(conn)

  let assert Ok(Nil) =
    sqlight.exec(
      "INSERT INTO transacoes (chat_id, remetente, tipo, conteudo, status, criado_em)
       VALUES ('lixo sem arroba', 'bot', 'texto', 'ruim', 'pendente', unixepoch() - 3600),
              ('chat1@c.us', 'bot', 'texto', 'boa', 'pendente', unixepoch() - 3600);",
      conn,
    )

  let assert Ok([boa]) = porta.obter_pendentes()
  boa.conteudo |> should.equal("boa")

  // A ruim saiu da fila de vez.
  let assert Ok(status) =
    sqlight.query(
      "SELECT status, erro FROM transacoes WHERE conteudo = 'ruim'",
      on: conn,
      with: [],
      expecting: {
        use status <- decode.field(0, decode.string)
        use motivo <- decode.field(1, decode.string)
        decode.success(#(status, motivo))
      },
    )
  status
  |> should.equal([#("descartada", "chat_id ilegível (descarte definitivo)")])
}
