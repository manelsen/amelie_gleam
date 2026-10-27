// Portão único de autorização (achados M1 e B4 do relatório de segurança).

import core/autorizacao
import core/processador
import dominio/acao
import dominio/mensagem.{Mensagem, Texto, TurnoUsuario}
import gleam/option.{None, Some}
import gleeunit/should
import helpers/fixtures

fn msg(chat_id: String, remetente: String, em_grupo: Bool) -> mensagem.Mensagem {
  Mensagem(
    chat_id: fixtures.id(chat_id),
    remetente: fixtures.id(remetente),
    message_id: None,
    corpo: Texto("oi"),
    timestamp: 0,
    em_grupo: em_grupo,
    nome_grupo: None,
    menciona_bot: False,
    legenda: None,
  )
}

fn admin() {
  Some(fixtures.id("tg:12345"))
}

pub fn admin_em_conversa_privada_test() {
  autorizacao.eh_admin(admin(), msg("tg:12345", "tg:12345", False))
  |> should.be_true
}

pub fn sem_admin_configurado_ninguem_e_admin_test() {
  autorizacao.eh_admin(None, msg("tg:12345", "tg:12345", False))
  |> should.be_false
}

pub fn admin_em_grupo_nao_e_admin_test() {
  autorizacao.eh_admin(admin(), msg("tg:-100999", "tg:12345", True))
  |> should.be_false
}

pub fn remetente_divergente_nao_e_admin_test() {
  // A cópia antiga em tratar_interno aceitava chat OU remetente.
  autorizacao.eh_admin(admin(), msg("tg:12345", "tg:666", False))
  |> should.be_false
}

pub fn trocar_modelo_exige_admin_test() {
  let troca =
    acao.AlterarModelo(
      fixtures.id("5531999990000@s.whatsapp.net"),
      "gemini",
      "gemini-2.5-pro",
    )
  autorizacao.permitido(
    troca,
    admin(),
    msg("5531999990000@s.whatsapp.net", "5531999990000@s.whatsapp.net", False),
  )
  |> should.be_false
  autorizacao.permitido(troca, admin(), msg("tg:12345", "tg:12345", False))
  |> should.be_true
}

pub fn listagens_exigem_admin_test() {
  autorizacao.exige_admin(acao.ListarUsuarios(fixtures.chat_id()))
  |> should.be_true
  autorizacao.exige_admin(acao.ListarGrupos(fixtures.chat_id()))
  |> should.be_true
  autorizacao.exige_admin(acao.ConsultarMetricas(fixtures.chat_id()))
  |> should.be_true
}

pub fn acoes_comuns_nao_exigem_admin_test() {
  autorizacao.exige_admin(acao.EnviarResposta(fixtures.chat_id(), "y"))
  |> should.be_false
  autorizacao.exige_admin(acao.LimparHistorico(fixtures.chat_id()))
  |> should.be_false
  autorizacao.exige_admin(acao.GerarEEnviar(fixtures.chat_id(), "y"))
  |> should.be_false
}

pub fn marcador_admin_so_vale_exato_test() {
  processador.tem_midia_no_historico([TurnoUsuario("[admin]")])
  |> should.be_true
  // Texto de usuário que só contém o marcador não destrava mais.
  processador.tem_midia_no_historico([
    TurnoUsuario("me ajuda [admin] por favor"),
  ])
  |> should.be_false
}
