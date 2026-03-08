import core/comando/dispatcher
import dominio/acao.{EnviarResposta, LimparHistorico, SalvarConfig}
import dominio/erro
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import helpers/fixtures

pub fn ajuda_retorna_texto_test() {
  let cfg = fixtures.config_padrao()
  let assert Ok([EnviarResposta(_, texto)]) = dispatcher.executar("ajuda", "", cfg)
  string.contains(texto, "Amélie") |> should.be_true
}

pub fn config_sem_args_retorna_config_test() {
  let cfg = fixtures.config_padrao()
  let assert Ok([EnviarResposta(_, texto)]) =
    dispatcher.executar("config", "", cfg)
  string.contains(texto, "gemini") |> should.be_true
}

pub fn config_com_args_retorna_erro_test() {
  let cfg = fixtures.config_padrao()
  dispatcher.executar("config", "foo", cfg) |> should.be_error
}

pub fn reset_retorna_tres_acoes_test() {
  let cfg = fixtures.config_padrao()
  let assert Ok([SalvarConfig(_), LimparHistorico(_), EnviarResposta(_, texto)]) =
    dispatcher.executar("reset", "", cfg)
  string.contains(texto, "resetados") |> should.be_true
}

pub fn reset_salva_config_padrao_test() {
  let cfg = fixtures.config_padrao()
  let assert Ok([SalvarConfig(nova_cfg), _, _]) =
    dispatcher.executar("reset", "", cfg)
  nova_cfg.chat_id |> should.equal(cfg.chat_id)
}

pub fn reset_inclui_limpar_historico_test() {
  let cfg = fixtures.config_padrao()
  let assert Ok([_, LimparHistorico(chat_id), _]) =
    dispatcher.executar("reset", "", cfg)
  chat_id |> should.equal(cfg.chat_id)
}

pub fn audio_on_salva_config_ativado_test() {
  // Começa com audio desativado
  let cfg = fixtures.config_midia_off()
  let assert Ok([SalvarConfig(nova_cfg), EnviarResposta(_, _)]) =
    dispatcher.executar("audio", "on", cfg)
  nova_cfg.audio_ativo |> should.be_true
}

pub fn audio_off_salva_config_desativado_test() {
  let cfg = fixtures.config_padrao()
  let assert Ok([SalvarConfig(nova_cfg), EnviarResposta(_, _)]) =
    dispatcher.executar("audio", "off", cfg)
  nova_cfg.audio_ativo |> should.be_false
}

pub fn audio_off_nao_afeta_outros_campos_test() {
  let cfg = fixtures.config_padrao()
  let assert Ok([SalvarConfig(nova_cfg), _]) =
    dispatcher.executar("audio", "off", cfg)
  nova_cfg.imagem_ativo |> should.be_true
  nova_cfg.video_ativo |> should.be_true
  nova_cfg.doc_ativo |> should.be_true
}

pub fn audio_sem_args_retorna_status_test() {
  let cfg = fixtures.config_padrao()
  let assert Ok([EnviarResposta(_, texto)]) =
    dispatcher.executar("audio", "", cfg)
  string.contains(texto, "audio") |> should.be_true
}

pub fn audio_arg_invalido_retorna_erro_test() {
  let cfg = fixtures.config_padrao()
  let result = dispatcher.executar("audio", "sim", cfg)
  result |> should.be_error
  let assert Error(erro.ErroValidacao("audio", _)) = result
}

pub fn imagem_on_salva_config_test() {
  let cfg = fixtures.config_midia_off()
  let assert Ok([SalvarConfig(nova_cfg), EnviarResposta(_, _)]) =
    dispatcher.executar("imagem", "on", cfg)
  nova_cfg.imagem_ativo |> should.be_true
}

pub fn video_on_salva_config_test() {
  let cfg = fixtures.config_midia_off()
  let assert Ok([SalvarConfig(nova_cfg), EnviarResposta(_, _)]) =
    dispatcher.executar("video", "on", cfg)
  nova_cfg.video_ativo |> should.be_true
}

pub fn doc_on_salva_config_test() {
  let cfg = fixtures.config_midia_off()
  let assert Ok([SalvarConfig(nova_cfg), EnviarResposta(_, _)]) =
    dispatcher.executar("doc", "on", cfg)
  nova_cfg.doc_ativo |> should.be_true
}

pub fn prompt_vazio_sem_prompt_test() {
  let cfg = fixtures.config_padrao()
  let assert Ok([EnviarResposta(_, texto)]) =
    dispatcher.executar("prompt", "", cfg)
  string.contains(texto, "Nenhum") |> should.be_true
}

pub fn prompt_vazio_com_prompt_existente_test() {
  let cfg = fixtures.config_com_prompt()
  let assert Ok([EnviarResposta(_, texto)]) =
    dispatcher.executar("prompt", "", cfg)
  string.contains(texto, "Prompt atual") |> should.be_true
}

pub fn prompt_reset_remove_prompt_test() {
  let cfg = fixtures.config_com_prompt()
  let assert Ok([SalvarConfig(nova_cfg), EnviarResposta(_, _)]) =
    dispatcher.executar("prompt", "reset", cfg)
  nova_cfg.prompt_sistema |> should.equal(None)
}

pub fn prompt_novo_salva_prompt_test() {
  let novo = "Você é um bot de testes."
  let cfg = fixtures.config_padrao()
  let assert Ok([SalvarConfig(nova_cfg), EnviarResposta(_, _)]) =
    dispatcher.executar("prompt", novo, cfg)
  nova_cfg.prompt_sistema |> should.equal(Some(novo))
}

pub fn cego_ativa_imagem_desativa_audio_test() {
  let cfg = fixtures.config_padrao()
  let assert Ok([SalvarConfig(nova_cfg), EnviarResposta(_, _)]) =
    dispatcher.executar("cego", "", cfg)
  nova_cfg.imagem_ativo |> should.be_true
  nova_cfg.audio_ativo |> should.be_false
}

pub fn cego_define_prompt_sistema_test() {
  let cfg = fixtures.config_padrao()
  let assert Ok([SalvarConfig(nova_cfg), _]) =
    dispatcher.executar("cego", "", cfg)
  let assert Some(_) = nova_cfg.prompt_sistema
}

pub fn comando_desconhecido_retorna_erro_test() {
  let cfg = fixtures.config_padrao()
  let result = dispatcher.executar("xyzzy", "", cfg)
  result |> should.be_error
  let assert Error(erro.ErroComandoDesconhecido("xyzzy")) = result
}
