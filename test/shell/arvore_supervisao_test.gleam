import gleam/erlang/process
import gleam/option.{Some}
import gleeunit/should
import helpers/portas_fake
import shell/arvore_supervisao
import shell/cache_ia
import shell/circuit_breaker
import shell/metricas

pub fn arvore_supervisao_inicializacao_test() {
  let transacoes = portas_fake.transacao_noop()
  let mensageiro = portas_fake.mensageiro_ok()

  let assert Ok(#(_sup, procs)) =
    arvore_supervisao.iniciar(transacoes, mensageiro)

  // 1. Circuit breaker responde normalmente
  circuit_breaker.pode_executar(procs.cb_gemini) |> should.be_true
  circuit_breaker.pode_executar(procs.cb_openrouter) |> should.be_true

  // 2. Cache IA armazena e recupera
  cache_ia.guardar(procs.cache_gemini, "chave_teste", "valor_teste")
  cache_ia.obter(procs.cache_gemini, "chave_teste")
  |> should.equal(Some("valor_teste"))

  // 3. Métricas acumulam
  metricas.registrar(procs.metricas, metricas.MensagensProcessadas)
  let estado_metricas = metricas.consultar(procs.metricas)
  estado_metricas.mensagens |> should.equal(1)
}

pub fn arvore_supervisao_recuperacao_apos_crash_test() {
  let transacoes = portas_fake.transacao_noop()
  let mensageiro = portas_fake.mensageiro_ok()

  let assert Ok(#(_sup, procs)) =
    arvore_supervisao.iniciar(transacoes, mensageiro)

  // Registra métrica inicial
  metricas.registrar(procs.metricas, metricas.MensagensProcessadas)
  { metricas.consultar(procs.metricas) }.mensagens |> should.equal(1)

  // Obtém o PID do processo atual
  let assert Ok(pid_antigo) = process.subject_owner(procs.metricas)

  // Simula um crash fatal no worker
  process.kill(pid_antigo)

  // Aguarda 100ms para o supervisor OneForOne reiniciar o processo
  process.sleep(100)

  // Verifica que o processo ressuscitou com um novo PID
  let assert Ok(pid_novo) = process.subject_owner(procs.metricas)
  { pid_antigo == pid_novo } |> should.be_false

  // O subject nomeado continua funcionando normalmente!
  metricas.registrar(procs.metricas, metricas.MensagensProcessadas)
  { metricas.consultar(procs.metricas) }.mensagens |> should.equal(1)
}

pub fn arvore_supervisao_isolamento_de_falhas_test() {
  let transacoes = portas_fake.transacao_noop()
  let mensageiro = portas_fake.mensageiro_ok()

  let assert Ok(#(_sup, procs)) =
    arvore_supervisao.iniciar(transacoes, mensageiro)

  // Salva dado no cache
  cache_ia.guardar(procs.cache_gemini, "teste_isolamento", "dado_protegido")

  // Mata o circuit breaker
  let assert Ok(pid_cb) = process.subject_owner(procs.cb_gemini)
  process.kill(pid_cb)

  process.sleep(100)

  // O cache permaneceu intacto e o dado ainda existe
  cache_ia.obter(procs.cache_gemini, "teste_isolamento")
  |> should.equal(Some("dado_protegido"))

  // E o circuit breaker foi reiniciado
  circuit_breaker.pode_executar(procs.cb_gemini) |> should.be_true
}
