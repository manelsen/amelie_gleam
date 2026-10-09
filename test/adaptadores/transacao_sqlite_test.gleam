import adaptadores/transacao_sqlite
import dominio/transacao.{Entregue, Pendente, Transacao}
import gleam/option.{None, Some}
import gleeunit/should
import sqlight

pub fn limpar_antigas_remove_transacoes_e_mensagens_expiradas_test() {
  use conn <- sqlight.with_connection("file:transacao_limpeza?mode=memory")
  let porta = transacao_sqlite.criar(conn)

  // 1. Cria transação entregue antiga (8 dias atrás)
  let _ =
    sqlight.exec(
      "INSERT INTO transacoes (chat_id, remetente, tipo, conteudo, status, criado_em)
       VALUES ('chat1', 'user1', 'texto', 'msg antiga', 'entregue', unixepoch() - 8 * 24 * 3600);",
      conn,
    )

  // 2. Cria transação entregue recente
  let tx_recente =
    Transacao(
      id: None,
      chat_id: "chat1",
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
       VALUES ('chat1', 'user1', 'texto', 'msg pendente antiga', 'pendente', unixepoch() - 8 * 24 * 3600);",
      conn,
    )

  // 4. Insere mensagem recebida antiga e mensagem recebida recente
  let _ =
    sqlight.exec(
      "INSERT INTO mensagens_recebidas (message_id, recebido_em)
       VALUES ('mid_antigo', unixepoch() - 8 * 24 * 3600);",
      conn,
    )
  let assert Ok(Nil) = porta.marcar_recebida("mid_recente")

  // 5. Executa limpar_antigas
  let assert Ok(Nil) = porta.limpar_antigas()

  // 6. Verifica deduplicação: mid_antigo foi apagado, mid_recente preservado
  porta.foi_recebida("mid_antigo")
  |> should.equal(Ok(False))

  porta.foi_recebida("mid_recente")
  |> should.equal(Ok(True))

  // 7. Verifica que a transação pendente continua existindo
  let assert Ok(pendentes) = porta.obter_pendentes()
  should.be_true(case pendentes {
    [tx] -> tx.conteudo == "msg pendente antiga" && tx.status == Pendente
    _ -> False
  })
}
