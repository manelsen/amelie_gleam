// Testes do Circuit Breaker e contenção no estado SemiAberto.

import gleam/erlang/process
import gleeunit/should
import shell/circuit_breaker.{
  Aberto, Config, Fechado, SemiAberto, iniciar_com_config, obter_estado,
  pode_executar, registrar_falha, registrar_sucesso,
}

pub fn circuito_inicia_fechado_e_permite_execucao_test() {
  let cfg = Config(limite_falhas: 3, reset_ms: 100, timeout_probe_ms: 50)
  let assert Ok(cb) = iniciar_com_config(cfg)

  pode_executar(cb) |> should.be_true
  case obter_estado(cb) {
    Fechado(0) -> Nil
    _ -> should.fail()
  }
}

pub fn circuito_abre_apos_atingir_limite_de_falhas_test() {
  let cfg = Config(limite_falhas: 3, reset_ms: 100, timeout_probe_ms: 50)
  let assert Ok(cb) = iniciar_com_config(cfg)

  // 1ª falha
  registrar_falha(cb)
  pode_executar(cb) |> should.be_true
  case obter_estado(cb) {
    Fechado(1) -> Nil
    _ -> should.fail()
  }

  // 2ª falha
  registrar_falha(cb)
  pode_executar(cb) |> should.be_true
  case obter_estado(cb) {
    Fechado(2) -> Nil
    _ -> should.fail()
  }

  // 3ª falha -> deve abrir o circuito
  registrar_falha(cb)
  pode_executar(cb) |> should.be_false
  case obter_estado(cb) {
    Aberto(_) -> Nil
    _ -> should.fail()
  }
}

pub fn circuito_bloqueia_durante_resfriamento_test() {
  let cfg = Config(limite_falhas: 2, reset_ms: 100, timeout_probe_ms: 50)
  let assert Ok(cb) = iniciar_com_config(cfg)

  registrar_falha(cb)
  registrar_falha(cb)

  // Aberto
  pode_executar(cb) |> should.be_false
  pode_executar(cb) |> should.be_false
}

pub fn semi_aberto_permite_apenas_um_probe_concorrente_test() {
  // Reset rápido de 40ms para teste determinístico
  let cfg = Config(limite_falhas: 2, reset_ms: 40, timeout_probe_ms: 200)
  let assert Ok(cb) = iniciar_com_config(cfg)

  registrar_falha(cb)
  registrar_falha(cb)

  // Circuito aberto
  pode_executar(cb) |> should.be_false

  // Aguarda expirar reset_ms
  process.sleep(50)

  // 1ª chamada transiciona para SemiAberto e recebe True (prova única)
  pode_executar(cb) |> should.be_true

  case obter_estado(cb) {
    SemiAberto(probe_em_voo: True, ..) -> Nil
    _ -> should.fail()
  }

  // Chamadas subsequentes concorrentes são bloqueadas enquanto o probe está em voo!
  pode_executar(cb) |> should.be_false
  pode_executar(cb) |> should.be_false

  // Quando o probe reporta sucesso, o circuito fecha e permite todas novamente
  registrar_sucesso(cb)
  case obter_estado(cb) {
    Fechado(0) -> Nil
    _ -> should.fail()
  }
  pode_executar(cb) |> should.be_true
  pode_executar(cb) |> should.be_true
}

pub fn semi_aberto_reabre_em_caso_de_falha_do_probe_test() {
  let cfg = Config(limite_falhas: 2, reset_ms: 40, timeout_probe_ms: 200)
  let assert Ok(cb) = iniciar_com_config(cfg)

  registrar_falha(cb)
  registrar_falha(cb)

  process.sleep(50)

  // Primeiro probe liberado
  pode_executar(cb) |> should.be_true

  // Probe falha -> reabre circuito imediatamente
  registrar_falha(cb)
  case obter_estado(cb) {
    Aberto(_) -> Nil
    _ -> should.fail()
  }

  pode_executar(cb) |> should.be_false
}

pub fn semi_aberto_permite_novo_probe_apos_timeout_do_anterior_test() {
  // timeout_probe_ms de 30ms
  let cfg = Config(limite_falhas: 2, reset_ms: 40, timeout_probe_ms: 30)
  let assert Ok(cb) = iniciar_com_config(cfg)

  registrar_falha(cb)
  registrar_falha(cb)

  process.sleep(50)

  // 1º probe iniciado
  pode_executar(cb) |> should.be_true

  // Bloqueado enquanto em voo
  pode_executar(cb) |> should.be_false

  // Se o probe original sumir ou travar, após timeout_probe_ms um novo probe pode tentar
  process.sleep(40)
  pode_executar(cb) |> should.be_true
}
