// Shell — executa os efeitos prescritos pelo core.
// Este módulo tem side effects: chama portas, grava histórico.

import core/acessibilidade
import core/anti_spam as core_anti_spam
import core/autorizacao
import core/privacidade
import core/processador
import core/prompt/montador
import dominio/acao.{
  AlterarModelo, AtivarPrompt, BuscarUrlEResponder, ConsultarMetricas,
  ConsultarSpammers, ConsultarStatus, DesbloquearChat, EnfileirarMidia,
  EnviarResposta, ExcluirPrompt, GerarEEnviar, LimparHistorico, ListarGrupos,
  ListarPrompts, ListarUsuarios, MidiaVideo, NaoResponder, ResetarWhatsApp,
  SalvarConfig, SalvarPrompt, SnapshotHistorico, SolicitarPareamento,
}
import dominio/config.{type Config}
import dominio/erro.{type Erro}
import dominio/mensagem.{
  type Mensagem, type Turno, Audio, Documento, Imagem, Texto, TurnoAssistente,
  TurnoUsuario, Video,
}
import dominio/provedores_config.{type ProvedoresConfig}
import dominio/transacao.{type TipoEntrega, RespostaIA, RespostaTexto}
import dominio/video_contexto.{type VideoContexto}
import gleam/bool
import gleam/int
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import logging
import portas/config_porta.{type ConfigPorta}
import portas/grupo_porta.{type GrupoPorta}
import portas/historico_porta.{type HistoricoPorta}
import portas/mensageiro_porta.{type MensageiroPorta}
import portas/ponte_porta.{type PontePorta, StatusPonte}
import portas/prompt_porta.{type PromptPorta}
import portas/spammer_porta.{type SpammerPorta}
import portas/transacao_porta.{type TransacaoPorta}
import portas/usuario_porta.{type UsuarioPorta}
import portas/video_contexto_porta.{type VideoContextoPorta}
import shell/anti_spam.{type AntiSpam}
import shell/arquivos_temporarios
import shell/despachante_ia
import shell/entrega_auditada
import shell/extrator_url
import shell/fila_midia.{type FilasMidia}
import shell/metricas.{type Metricas}
import shell/sistema

/// O history sync do WhatsApp reenvia o histórico completo ao reconectar;
/// mensagens mais antigas que isso já foram respondidas antes.
const idade_maxima_mensagem_s = 172_800

/// Depois disso, perguntas sobre o último vídeo não usam mais o arquivo dele.
const validade_contexto_video_s = 1800

const aviso_restrito = "⛔ Comando restrito ao administrador."

const aviso_erro_generico = "⚠️ Desculpe, ocorreu um erro ao processar sua mensagem. Tente novamente."

const aviso_video_expirado = "👋 O período de dúvidas sobre o vídeo anterior expirou (30 min). Por favor, envie uma nova mídia (áudio, foto, vídeo ou documento) para continuar!"

const aviso_video_encerrado = "👋 Já encerramos as dúvidas sobre este vídeo. Para continuar, envie uma nova mídia (áudio, foto, vídeo ou documento)!"

const prompt_resumo = "Resuma esta conversa de forma concisa e acessível, destacando os pontos principais, decisões e tópicos discutidos:\n\n"

pub type Portas {
  Portas(
    mensageiro: MensageiroPorta,
    despachante_ia: despachante_ia.DespachanteIA,
    config: ConfigPorta,
    historico: HistoricoPorta,
    fila: FilasMidia,
    prompts: PromptPorta,
    metricas: Metricas,
    usuarios: UsuarioPorta,
    grupos: GrupoPorta,
    transacoes: TransacaoPorta,
    provedores_config: ProvedoresConfig,
    anti_spam: AntiSpam,
    spammers: SpammerPorta,
    video_contexto: VideoContextoPorta,
    ponte: PontePorta,
  )
}

pub fn extrair_trace_id(msg: Mensagem) -> String {
  let id = case msg.message_id {
    option.Some(id) if id != "" -> id
    _ -> "req_" <> int.to_string(msg.timestamp) <> "_" <> msg.remetente
  }
  string.slice(id, 0, 5)
}

pub fn tratar(msg: Mensagem, portas: Portas) -> Result(Nil, Erro) {
  let trace_id = extrair_trace_id(msg)
  logging.log(
    logging.Info,
    "["
      <> trace_id
      <> "] Mensagem recebida do chat "
      <> privacidade.mascarar_id(msg.chat_id)
      <> " (remetente: "
      <> privacidade.mascarar_id(msg.remetente)
      <> ")",
  )

  use <- bool.lazy_guard(mensagem_antiga(msg), fn() {
    logging.log(
      logging.Info,
      "["
        <> trace_id
        <> "] Mensagem ignorada por ser muito antiga (ts="
        <> int.to_string(msg.timestamp)
        <> "): "
        <> privacidade.mascarar_id(msg.chat_id),
    )
    limpar_midia_se_descartada(msg)
    Ok(Nil)
  })
  use <- bool.lazy_guard(ja_processada(msg, portas), fn() {
    logging.log(
      logging.Info,
      "["
        <> trace_id
        <> "] Mensagem ja processada, ignorando: "
        <> option.unwrap(msg.message_id, ""),
    )
    limpar_midia_se_descartada(msg)
    Ok(Nil)
  })
  processar_mensagem_com_anti_spam(msg, portas)
}

fn mensagem_antiga(msg: Mensagem) -> Bool {
  msg.timestamp > 0
  && sistema.agora_s() - msg.timestamp > idade_maxima_mensagem_s
}

/// Deduplicação: o history sync pode reenviar mensagens já processadas.
/// Marca a mensagem como recebida e diz se ela já tinha passado por aqui.
/// Sem message_id (raro) ou com o banco fora, a mensagem é processada.
fn ja_processada(msg: Mensagem, portas: Portas) -> Bool {
  case msg.message_id {
    option.None -> False
    option.Some(msg_id) ->
      case portas.transacoes.foi_recebida(msg_id) {
        Ok(True) -> True
        Ok(False) -> {
          portas.transacoes.marcar_recebida(msg_id)
          |> sistema.registrar_falha("Falha ao marcar mensagem como recebida")
          False
        }
        Error(_) -> False
      }
  }
}

fn processar_mensagem_com_anti_spam(
  msg: Mensagem,
  portas: Portas,
) -> Result(Nil, Erro) {
  case
    anti_spam.verificar(portas.anti_spam, msg.chat_id, msg.remetente, msg.corpo)
  {
    core_anti_spam.Permitido -> processar_mensagem(msg, portas)
    core_anti_spam.AvisoLimite(motivo) -> avisar_limite(motivo, msg, portas)
    core_anti_spam.Silenciado(notificar_admin) ->
      descartar_silenciado(notificar_admin, msg, portas)
  }
}

fn avisar_limite(
  motivo: String,
  msg: Mensagem,
  portas: Portas,
) -> Result(Nil, Erro) {
  let tel = core_anti_spam.extrair_telefone(msg.chat_id, msg.remetente)
  let strike = case string.contains(motivo, "5 minutos") {
    True -> 2
    False -> 1
  }
  portas.spammers.registrar(msg.chat_id, msg.remetente, tel, motivo, strike)
  |> sistema.registrar_falha("Falha ao registrar incidente de spam")
  logging.log(
    logging.Warning,
    "["
      <> extrair_trace_id(msg)
      <> "] Rate limit acionado para "
      <> privacidade.mascarar_id(tel)
      <> " ("
      <> privacidade.mascarar_id(msg.chat_id)
      <> "): "
      <> motivo,
  )
  limpar_midia_se_descartada(msg)
  avisar(msg.chat_id, motivo, portas)
}

fn descartar_silenciado(
  notificar_admin: option.Option(String),
  msg: Mensagem,
  portas: Portas,
) -> Result(Nil, Erro) {
  let tel = core_anti_spam.extrair_telefone(msg.chat_id, msg.remetente)
  portas.spammers.registrar(
    msg.chat_id,
    msg.remetente,
    tel,
    "Quarentena / Blackhole",
    3,
  )
  |> sistema.registrar_falha("Falha ao registrar incidente de spam")
  logging.log(
    logging.Warning,
    "["
      <> extrair_trace_id(msg)
      <> "] Mensagem descartada silenciosamente por quarentena anti-spam: "
      <> privacidade.mascarar_id(tel)
      <> " ("
      <> privacidade.mascarar_id(msg.chat_id)
      <> ")",
  )
  limpar_midia_se_descartada(msg)
  case notificar_admin, sistema.admin_chat_id() {
    option.Some(alerta), admin_id if admin_id != "" ->
      avisar("tg:" <> admin_id, alerta, portas)
    _, _ -> Ok(Nil)
  }
}

fn limpar_midia_se_descartada(msg: Mensagem) -> Nil {
  case msg.corpo {
    mensagem.Video(caminho_temp: caminho, ..) -> {
      let _ = arquivos_temporarios.deletar(caminho)
      Nil
    }
    _ -> Nil
  }
}

fn processar_mensagem(msg: Mensagem, portas: Portas) -> Result(Nil, Erro) {
  let trace_id = extrair_trace_id(msg)
  logging.log(
    logging.Info,
    "["
      <> trace_id
      <> "] Processando mensagem: "
      <> privacidade.mascarar_id(msg.chat_id),
  )

  portas.usuarios.registrar(msg.chat_id)
  |> sistema.registrar_falha("Falha ao registrar usuário")
  case msg.em_grupo {
    True ->
      portas.grupos.registrar(
        msg.chat_id,
        option.unwrap(msg.nome_grupo, "Grupo"),
      )
      |> sistema.registrar_falha("Falha ao registrar grupo")
    False -> Nil
  }

  metricas.registrar(portas.metricas, metricas.MensagensProcessadas)
  use e <- result.try_recover(tratar_interno(msg, portas))
  limpar_midia_se_descartada(msg)
  metricas.registrar(portas.metricas, metricas.Erros)
  logging.log(
    logging.Warning,
    "["
      <> trace_id
      <> "] Erro ao processar mensagem de "
      <> privacidade.mascarar_id(msg.remetente)
      <> ": "
      <> erro.descricao(e),
  )
  let _ = avisar(msg.chat_id, aviso_erro_generico, portas)
  Error(e)
}

fn tratar_interno(msg: Mensagem, portas: Portas) -> Result(Nil, Erro) {
  use cfg <- result.try(portas.config.obter(msg.chat_id))
  use hist <- result.try(portas.historico.obter(msg.chat_id))
  let admin_id = sistema.admin_chat_id()
  let hist_efetivo = case autorizacao.eh_admin(admin_id, msg) {
    True -> [TurnoUsuario(processador.marcador_admin), ..hist]
    False -> hist
  }
  use acoes <- result.try(processador.processar(msg, cfg, hist_efetivo))
  let vai_enfileirar_video =
    list.any(acoes, fn(a) {
      case a {
        EnfileirarMidia(_, MidiaVideo) -> True
        _ -> False
      }
    })
  case vai_enfileirar_video {
    False -> limpar_midia_se_descartada(msg)
    True -> Nil
  }
  acoes
  |> list.map(executar_acao(_, admin_id, msg, cfg, hist, portas))
  |> result.all
  |> result.map(fn(_) { Nil })
}

/// Executa uma ação prescrita pelo core, depois de passar pelo portão único
/// de autorização: ações administrativas de quem não é admin são recusadas
/// aqui, antes de qualquer efeito.
fn executar_acao(
  acao: acao.Acao,
  admin_id: String,
  msg: Mensagem,
  cfg: Config,
  hist: List(Turno),
  portas: Portas,
) -> Result(Nil, Erro) {
  use <- bool.lazy_guard(!autorizacao.permitido(acao, admin_id, msg), fn() {
    avisar(msg.chat_id, aviso_restrito, portas)
  })
  case acao {
    GerarEEnviar(para, prompt) ->
      gerar_e_enviar(para, prompt, msg, cfg, hist, portas)
    BuscarUrlEResponder(para, texto, url) ->
      buscar_url_e_responder(para, texto, url, msg, cfg, hist, portas)
    EnviarResposta(para, corpo) ->
      entregar(para, RespostaTexto, corpo, msg, portas)
    SalvarConfig(nova_cfg) -> portas.config.salvar(nova_cfg)
    LimparHistorico(chat_id) -> limpar_historico(chat_id, cfg, portas)
    EnfileirarMidia(chat_id, tipo) ->
      enfileirar_midia(chat_id, tipo, msg, cfg, portas)
    SalvarPrompt(chat_id, nome, texto) ->
      portas.prompts.definir(chat_id, nome, texto)
    ExcluirPrompt(chat_id, nome) -> portas.prompts.excluir(chat_id, nome)
    AtivarPrompt(chat_id, nome) -> ativar_prompt(chat_id, nome, cfg, portas)
    ListarPrompts(chat_id) -> listar_prompts(chat_id, portas)
    ConsultarMetricas(chat_id) ->
      responder(
        chat_id,
        metricas.formatar(metricas.consultar(portas.metricas)),
        portas,
      )
    ListarUsuarios(chat_id) ->
      responder(
        chat_id,
        formatar_lista("👥 Usuários ativos:", portas.usuarios.listar()),
        portas,
      )
    ListarGrupos(chat_id) ->
      responder(
        chat_id,
        formatar_lista("👥 Grupos ativos:", portas.grupos.listar()),
        portas,
      )
    SnapshotHistorico(chat_id) -> resumir_historico(chat_id, cfg, portas)
    AlterarModelo(chat_id, provedor, modelo) ->
      alterar_modelo(chat_id, provedor, modelo, msg, cfg, portas)
    SolicitarPareamento(chat_id, args) ->
      solicitar_pareamento(chat_id, args, portas)
    ConsultarStatus(chat_id) -> consultar_status(chat_id, portas)
    ResetarWhatsApp(chat_id, args) -> resetar_whatsapp(chat_id, args, portas)
    DesbloquearChat(chat_id, alvo) -> desbloquear_chat(chat_id, alvo, portas)
    ConsultarSpammers(chat_id) -> consultar_spammers(chat_id, portas)
    NaoResponder -> Ok(Nil)
  }
}

// ---------------------------------------------------------------------------
// Respostas da IA
// ---------------------------------------------------------------------------

fn gerar_e_enviar(
  para: String,
  prompt: String,
  msg: Mensagem,
  cfg: Config,
  hist: List(Turno),
  portas: Portas,
) -> Result(Nil, Erro) {
  case portas.video_contexto.obter(para) {
    Ok(option.Some(ctx)) ->
      responder_sobre_video(para, ctx, msg, cfg, hist, portas)
    _ -> {
      logging.log(
        logging.Info,
        "["
          <> extrair_trace_id(msg)
          <> "] Enviando texto gerado pela IA para "
          <> privacidade.mascarar_id(para),
      )
      responder_com_ia(para, prompt, msg, cfg, hist, portas)
    }
  }
}

fn buscar_url_e_responder(
  para: String,
  texto: String,
  url: String,
  msg: Mensagem,
  cfg: Config,
  hist: List(Turno),
  portas: Portas,
) -> Result(Nil, Erro) {
  let prompt = case extrator_url.buscar(portas.ponte, url) {
    Ok(conteudo) -> montador.montar_com_url(texto, url, conteudo, cfg, hist)
    Error(_) -> montador.montar(texto, cfg, hist)
  }
  responder_com_ia(para, prompt, msg, cfg, hist, portas)
}

fn responder_com_ia(
  para: String,
  prompt: String,
  msg: Mensagem,
  cfg: Config,
  hist: List(Turno),
  portas: Portas,
) -> Result(Nil, Erro) {
  use resposta <- result.try(despachante_ia.gerar_texto(
    portas.despachante_ia,
    prompt,
    hist,
    cfg.provedor,
    cfg.modelo,
  ))
  use resposta_limpa <- result.try(entregar_resposta_ia(
    para,
    resposta,
    extrair_texto_usuario(msg),
    msg,
    portas,
  ))
  portas.historico.adicionar(msg.chat_id, TurnoAssistente(resposta_limpa))
}

/// Pergunta de acompanhamento sobre o último vídeo do chat: responde com o
/// arquivo do vídeo enquanto houver cota e o contexto não tiver expirado.
fn responder_sobre_video(
  para: String,
  ctx: VideoContexto,
  msg: Mensagem,
  cfg: Config,
  hist: List(Turno),
  portas: Portas,
) -> Result(Nil, Erro) {
  let expirado = sistema.agora_s() - ctx.criado_em >= validade_contexto_video_s
  use <- bool.lazy_guard(expirado, fn() {
    encerrar_contexto_video(para, ctx.uri, cfg, portas)
    entregar(para, RespostaTexto, aviso_video_expirado, msg, portas)
  })
  use <- bool.lazy_guard(ctx.perguntas_restantes <= 0, fn() {
    encerrar_contexto_video(para, ctx.uri, cfg, portas)
    entregar(para, RespostaTexto, aviso_video_encerrado, msg, portas)
  })

  let texto_usuario = extrair_texto_usuario(msg)
  logging.log(
    logging.Info,
    "["
      <> extrair_trace_id(msg)
      <> "] Respondendo dúvida de follow-up sobre vídeo para "
      <> privacidade.mascarar_id(para)
      <> " ("
      <> int.to_string(ctx.perguntas_restantes)
      <> " pergunta(s) restante(s))",
  )
  use resposta <- result.try(despachante_ia.processar_video(
    portas.despachante_ia,
    ctx.uri,
    montador.montar_followup_video(cfg, hist, texto_usuario),
    cfg.provedor,
    cfg.modelo,
  ))
  use resposta_limpa <- result.try(entregar_resposta_ia(
    para,
    resposta,
    texto_usuario,
    msg,
    portas,
  ))
  portas.historico.adicionar(msg.chat_id, TurnoAssistente(resposta_limpa))
  |> sistema.registrar_falha("Falha ao gravar resposta no histórico")

  let restantes =
    portas.video_contexto.decrementar_perguntas(para)
    |> result.unwrap(or: 0)
  use <- bool.guard(restantes > 0, Ok(Nil))
  encerrar_contexto_video(para, ctx.uri, cfg, portas)
  Ok(Nil)
}

/// Entrega a resposta da IA ao usuário e grava a pergunta no histórico.
/// Devolve a resposta já sanitizada, para o chamador gravá-la também.
fn entregar_resposta_ia(
  para: String,
  resposta: String,
  texto_usuario: String,
  msg: Mensagem,
  portas: Portas,
) -> Result(String, Erro) {
  let resposta_limpa = acessibilidade.sanitizar_saida_voz(resposta)
  use _ <- result.try(entregar(para, RespostaIA, resposta_limpa, msg, portas))
  use _ <- result.try(portas.historico.adicionar(
    msg.chat_id,
    TurnoUsuario(texto_usuario),
  ))
  Ok(resposta_limpa)
}

/// Esquece o vídeo do chat e apaga o arquivo dele no provedor de IA.
fn encerrar_contexto_video(
  chat_id: String,
  uri: String,
  cfg: Config,
  portas: Portas,
) -> Nil {
  portas.video_contexto.remover(chat_id)
  |> sistema.registrar_falha("Falha ao remover contexto de vídeo")
  apagar_video_no_provedor(uri, cfg, portas)
}

fn apagar_video_no_provedor(uri: String, cfg: Config, portas: Portas) -> Nil {
  despachante_ia.deletar_arquivo(portas.despachante_ia, uri, cfg.provedor)
  |> sistema.registrar_falha("Falha ao apagar vídeo no provedor de IA")
}

// ---------------------------------------------------------------------------
// Histórico, mídia e prompts
// ---------------------------------------------------------------------------

fn limpar_historico(
  chat_id: String,
  cfg: Config,
  portas: Portas,
) -> Result(Nil, Erro) {
  case portas.video_contexto.remover(chat_id) {
    Ok(option.Some(uri)) -> apagar_video_no_provedor(uri, cfg, portas)
    _ -> Nil
  }
  portas.historico.limpar(chat_id)
}

fn enfileirar_midia(
  chat_id: String,
  tipo: acao.TipoMidia,
  msg: Mensagem,
  cfg: Config,
  portas: Portas,
) -> Result(Nil, Erro) {
  logging.log(
    logging.Info,
    "Enfileirando mídia para processamento no chat "
      <> privacidade.mascarar_id(chat_id),
  )
  portas.historico.adicionar(chat_id, TurnoUsuario(extrair_texto_usuario(msg)))
  |> sistema.registrar_falha("Falha ao gravar mídia no histórico")
  let ia_porta =
    despachante_ia.como_porta(despachante_ia.DespachanteIAPorta(
      despachante: portas.despachante_ia,
      provedor: cfg.provedor,
      modelo: cfg.modelo,
    ))
  fila_midia.enfileirar(
    portas.fila,
    chat_id,
    msg,
    tipo,
    fila_midia.Contexto(
      cfg:,
      ia: ia_porta,
      mensageiro: portas.mensageiro,
      transacoes: portas.transacoes,
      historico: portas.historico,
      video_contexto: portas.video_contexto,
    ),
  )
}

fn ativar_prompt(
  chat_id: String,
  nome: String,
  cfg: Config,
  portas: Portas,
) -> Result(Nil, Erro) {
  use maybe_texto <- result.try(portas.prompts.obter(chat_id, nome))
  case maybe_texto {
    option.Some(texto) -> {
      let nova = config.Config(..cfg, prompt_sistema: option.Some(texto))
      use _ <- result.try(portas.config.salvar(nova))
      responder(chat_id, "Prompt `" <> nome <> "` ativado.", portas)
    }
    option.None ->
      responder(chat_id, "Prompt `" <> nome <> "` não encontrado.", portas)
  }
}

fn listar_prompts(chat_id: String, portas: Portas) -> Result(Nil, Erro) {
  use nomes <- result.try(portas.prompts.listar(chat_id))
  let texto = case nomes {
    [] -> "Nenhum prompt salvo."
    _ ->
      "*Prompts salvos:*\n\n"
      <> string.join(list.map(nomes, fn(n) { "- `" <> n <> "`" }), "\n")
  }
  responder(chat_id, texto, portas)
}

fn formatar_lista(titulo: String, itens: Result(List(String), Erro)) -> String {
  case itens {
    Ok(itens) -> titulo <> "\n" <> string.join(itens, "\n")
    Error(_) -> "Vazio ou Erro"
  }
}

fn resumir_historico(
  chat_id: String,
  cfg: Config,
  portas: Portas,
) -> Result(Nil, Erro) {
  logging.log(
    logging.Info,
    "Fazendo snapshot e resumo do histórico do chat "
      <> privacidade.mascarar_id(chat_id),
  )
  use hist <- result.try(portas.historico.obter(chat_id))
  let turnos = list.length(hist)
  use <- bool.lazy_guard(turnos < 2, fn() {
    responder(
      chat_id,
      "Ainda não há mensagens suficientes no histórico para gerar um resumo.",
      portas,
    )
  })

  use resumo <- result.try(despachante_ia.gerar_texto(
    portas.despachante_ia,
    prompt_resumo <> formatar_conversa(hist),
    [],
    cfg.provedor,
    cfg.modelo,
  ))
  let resumo_limpo = acessibilidade.sanitizar_saida_voz(resumo)

  // Compacta no banco se houver 10 ou mais turnos acumulados
  use _ <- result.try(case turnos >= 10 {
    True -> {
      use _ <- result.try(portas.historico.limpar(chat_id))
      portas.historico.adicionar(
        chat_id,
        TurnoUsuario("Contexto anterior resumido: " <> resumo_limpo),
      )
    }
    False -> Ok(Nil)
  })

  responder(chat_id, "📝 *Resumo da conversa:*\n\n" <> resumo_limpo, portas)
}

fn formatar_conversa(hist: List(Turno)) -> String {
  hist
  |> list.map(fn(t) {
    case t {
      TurnoUsuario(c) -> "Usuário: " <> c
      TurnoAssistente(c) -> "Amélie: " <> c
    }
  })
  |> string.join("\n")
}

fn alterar_modelo(
  chat_id: String,
  provedor: String,
  modelo: String,
  msg: Mensagem,
  cfg: Config,
  portas: Portas,
) -> Result(Nil, Erro) {
  case
    provedores_config.validar_modelo(portas.provedores_config, provedor, modelo)
  {
    Ok(provedor_valido) -> {
      let nova = config.Config(..cfg, provedor: provedor_valido, modelo: modelo)
      use _ <- result.try(portas.config.salvar(nova))
      entregar(
        chat_id,
        RespostaTexto,
        "Modelo alterado: `" <> provedor <> "/" <> modelo <> "`",
        msg,
        portas,
      )
    }
    Error(e) ->
      entregar(chat_id, RespostaTexto, "❌ " <> erro.descricao(e), msg, portas)
  }
}

// ---------------------------------------------------------------------------
// Comandos administrativos (já autorizados por executar_acao)
// ---------------------------------------------------------------------------

fn solicitar_pareamento(
  chat_id: String,
  args: String,
  portas: Portas,
) -> Result(Nil, Erro) {
  use <- bool.lazy_guard(whatsapp_conectado(portas.ponte), fn() {
    avisar(
      chat_id,
      "✅ O WhatsApp já está conectado e funcionando perfeitamente!",
      portas,
    )
  })
  case telefone_informado(args) {
    "" ->
      avisar(
        chat_id,
        "⚠️ WhatsApp desconectado. Por favor, informe seu número com DDD.\nEx: `/parear 5531999990000`",
        portas,
      )
    numero ->
      case portas.ponte.pedir_codigo_pareamento(numero) {
        Ok(codigo) ->
          avisar(
            chat_id,
            "📱 *Código de pareamento gerado:*\n`"
              <> codigo
              <> "` (para +"
              <> numero
              <> ")\n\n"
              <> "👉 *No WhatsApp do seu celular:*\n"
              <> "Aparelhos conectados > Conectar com número de telefone > Digite o código.",
            portas,
          )
        Error(motivo) ->
          avisar(chat_id, "❌ Falha ao gerar pairing code: " <> motivo, portas)
      }
  }
}

fn whatsapp_conectado(ponte: PontePorta) -> Bool {
  case ponte.checar_status() {
    Ok(StatusPonte(_, True)) -> True
    _ -> False
  }
}

/// O telefone passado no comando ou, sem ele, o MOBILE_NUMBER configurado.
fn telefone_informado(args: String) -> String {
  case string.trim(args) {
    "" -> sistema.ler_env_ou("MOBILE_NUMBER", "")
    numero -> numero
  }
}

fn consultar_status(chat_id: String, portas: Portas) -> Result(Nil, Erro) {
  let status_wa = case portas.ponte.checar_status() {
    Ok(StatusPonte(_, True)) -> "🟢 Conectado"
    Ok(StatusPonte(_, False)) -> "🟡 Desconectado (aguardando login)"
    Error(_) -> "🔴 Inacessível"
  }
  let estado = metricas.consultar(portas.metricas)
  let total_midias =
    estado.imagens
    + estado.audios
    + estado.videos
    + estado.documentos
    + estado.stickers

  avisar(
    chat_id,
    "📊 *Painel Administrativo — Amélie*\n\n"
      <> "*Canais de Mensageria:*\n"
      <> "• *WhatsApp:* "
      <> status_wa
      <> "\n"
      <> "• *Telegram:* 🟢 Ativo (Poller operacional)\n\n"
      <> "*Métricas BEAM:*\n"
      <> "• Memória total: `"
      <> int.to_string(metricas.memoria_total_mb())
      <> " MB`\n"
      <> "• Memória processos: `"
      <> int.to_string(metricas.memoria_processos_mb())
      <> " MB`\n"
      <> "• Processos OTP: `"
      <> int.to_string(metricas.contagem_processos())
      <> "`\n\n"
      <> "*Mensagens & Mídia:*\n"
      <> "• Mensagens processadas: `"
      <> int.to_string(estado.mensagens)
      <> "`\n"
      <> "• Erros registrados: `"
      <> int.to_string(estado.erros)
      <> "`\n"
      <> "• Mídias processadas: `"
      <> int.to_string(total_midias)
      <> "`\n"
      <> "• Chats em quarentena (anti-spam): `"
      <> int.to_string(anti_spam.contar_silenciados(portas.anti_spam))
      <> "`",
    portas,
  )
}

fn resetar_whatsapp(
  chat_id: String,
  args: String,
  portas: Portas,
) -> Result(Nil, Erro) {
  let tel = telefone_informado(args)
  case portas.ponte.resetar_sessao(tel) {
    Ok(Nil) -> {
      let texto = case tel {
        "" ->
          "🔄 *Reset do WhatsApp iniciado!*\n\nSessão anterior desconectada e dados locais limpos.\nPara parear um novo celular, execute: `/parear <telefone>`"
        num ->
          "🔄 *Reset do WhatsApp iniciado!*\n\nSessão anterior desconectada e dados locais limpos para o número `+"
          <> num
          <> "`.\nUm novo código de pareamento será enviado aqui em instantes."
      }
      avisar(chat_id, texto, portas)
    }
    Error(motivo) ->
      avisar(
        chat_id,
        "❌ Falha ao solicitar reset do WhatsApp: " <> motivo,
        portas,
      )
  }
}

fn desbloquear_chat(
  chat_id: String,
  alvo: String,
  portas: Portas,
) -> Result(Nil, Erro) {
  case string.trim(alvo) {
    "" ->
      avisar(
        chat_id,
        "⚠️ Informe o chat_id a ser desbloqueado.\nEx: `.unban 5531999990000`",
        portas,
      )
    alvo_id ->
      case anti_spam.desbloquear(portas.anti_spam, alvo_id) {
        True ->
          avisar(
            chat_id,
            "✅ Chat `" <> alvo_id <> "` desbloqueado com sucesso!",
            portas,
          )
        False ->
          avisar(
            chat_id,
            "ℹ️ O chat `" <> alvo_id <> "` não estava em quarentena ou bloqueio.",
            portas,
          )
      }
  }
}

fn consultar_spammers(chat_id: String, portas: Portas) -> Result(Nil, Erro) {
  let texto = case portas.spammers.listar_top(10) {
    Ok([]) -> "🛡️ *Anti-Spam:* Nenhum incidente registrado no banco de dados."
    Ok(lista) ->
      "🛡️ *Spammers Registrados (Top 10):*\n\n"
      <> {
        lista
        |> list.map(fn(spammer) {
          "• `"
          <> spammer.telefone
          <> "` — "
          <> int.to_string(spammer.total_incidentes)
          <> " ocorrência(s) (strike máx: "
          <> int.to_string(spammer.ultimo_strike)
          <> ")"
        })
        |> string.join("\n")
      }
      <> "\n\n💡 Use `.unban <chat_id_ou_telefone>` para liberar."
    Error(_) -> "Erro ao consultar spammers no banco de dados."
  }
  avisar(chat_id, texto, portas)
}

// ---------------------------------------------------------------------------
// Envio
// ---------------------------------------------------------------------------

// Envia citando a mensagem original quando possível; cai em envio simples caso contrário.
fn entregar(
  para: String,
  tipo: TipoEntrega,
  conteudo: String,
  msg: Mensagem,
  portas: Portas,
) -> Result(Nil, Erro) {
  let conteudo_sanitizado = acessibilidade.sanitizar_saida_voz(conteudo)
  case msg.message_id {
    option.Some(mid) ->
      entrega_auditada.enviar_citando(
        para,
        tipo,
        conteudo_sanitizado,
        mid,
        msg.remetente,
        portas.mensageiro,
        portas.transacoes,
      )
    option.None ->
      entrega_auditada.enviar(
        para,
        tipo,
        conteudo_sanitizado,
        portas.mensageiro,
        portas.transacoes,
      )
  }
}

/// Resposta de texto auditada, sem citar a mensagem original.
fn responder(para: String, texto: String, portas: Portas) -> Result(Nil, Erro) {
  entrega_auditada.enviar(
    para,
    RespostaTexto,
    texto,
    portas.mensageiro,
    portas.transacoes,
  )
}

/// Aviso direto pelo mensageiro, sem auditoria: recusas, avisos de limite e
/// respostas administrativas. Uma falha de envio vai para o log e não vira
/// erro da mensagem, porque o usuário não teria como receber o aviso de erro.
fn avisar(para: String, texto: String, portas: Portas) -> Result(Nil, Erro) {
  portas.mensageiro.enviar(para, texto)
  |> sistema.registrar_falha(
    "Falha ao enviar aviso para " <> privacidade.mascarar_id(para),
  )
  Ok(Nil)
}

fn extrair_texto_usuario(msg: Mensagem) -> String {
  case msg.corpo {
    Texto(body) -> body
    Imagem(..) -> "[imagem]"
    Audio(..) -> "[áudio]"
    Video(..) -> "[vídeo]"
    Documento(nome: nome, ..) -> "[documento: " <> nome <> "]"
    mensagem.Sticker(..) -> "[sticker]"
    mensagem.MidiaIndisponivel(..) -> "[mídia indisponível]"
    mensagem.Comando(nome, args) -> "." <> nome <> " " <> args
  }
}
