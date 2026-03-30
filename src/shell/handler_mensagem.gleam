// Shell — executa os efeitos prescritos pelo core.
// Este módulo tem side effects: chama portas, grava histórico.

import core/ia_dispatcher
import core/processador
import core/prompt/builder
import dominio/acao.{
  AlterarModelo, AtivarPrompt, BuscarUrlEResponder, ConsultarMetricas,
  EnfileirarMidia, EnviarReacao, EnviarResposta, EnviarTexto, ExcluirPrompt,
  LimparHistorico, ListarGrupos, ListarPrompts, ListarUsuarios, NaoResponder,
  SalvarConfig, SalvarPrompt, SnapshotHistorico,
}
import dominio/config
import dominio/erro.{type Erro}
import dominio/mensagem.{
  type Mensagem, type Turno, Audio, Documento, Imagem, Texto, TurnoAssistente,
  TurnoUsuario, Video,
}
import dominio/providers_config.{type ProvidersConfig}
import gleam/int
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import logging
import portas/config_porta.{type ConfigPorta}
import portas/grupo_porta.{type GrupoPorta}
import portas/historico_porta.{type HistoricoPorta}
import portas/prompt_porta.{type PromptPorta}
import portas/transacao_porta.{type TransacaoPorta}
import portas/usuario_porta.{type UsuarioPorta}
import portas/whatsapp_porta.{type WhatsappPorta}
import shell/entrega_auditada
import shell/fila_midia.{type FilasMidia}
import shell/metricas.{type Metricas}
import shell/url_scraper

pub type Portas {
  Portas(
    whatsapp: WhatsappPorta,
    ia_dispatcher: ia_dispatcher.IADispatcher,
    config: ConfigPorta,
    historico: HistoricoPorta,
    fila: FilasMidia,
    prompts: PromptPorta,
    metricas: Metricas,
    usuarios: UsuarioPorta,
    grupos: GrupoPorta,
    transacoes: TransacaoPorta,
    providers_config: ProvidersConfig,
  )
}

pub fn handle(msg: Mensagem, portas: Portas) -> Result(Nil, Erro) {
  logging.log(
    logging.Info,
    "Mensagem recebida do chat "
      <> msg.chat_id
      <> " (remetente: "
      <> msg.remetente
      <> ")",
  )

  // Deduplicação: history sync pode reenviar mensagens já processadas.
  // Mensagens sem message_id (raro) são sempre processadas.
  case msg.message_id {
    option.Some(msg_id) -> {
      case portas.transacoes.foi_recebida(msg_id) {
        Ok(True) -> {
          logging.log(logging.Info, "Mensagem ja processada, ignorando: " <> msg_id)
          Ok(Nil)
        }
        Ok(False) -> {
          let _ = portas.transacoes.marcar_recebida(msg_id)
          processar_mensagem(msg, portas)
        }
        Error(_) -> processar_mensagem(msg, portas)
      }
    }
    option.None -> processar_mensagem(msg, portas)
  }
}

fn processar_mensagem(msg: Mensagem, portas: Portas) -> Result(Nil, Erro) {
  logging.log(logging.Info, "Processando mensagem: " <> msg.chat_id)

  let _ = portas.usuarios.registrar(msg.chat_id)

  case msg.em_grupo {
    True -> {
      let nome = option.unwrap(msg.nome_grupo, "Grupo")
      let _ = portas.grupos.registrar(msg.chat_id, nome)
      Nil
    }
    False -> Nil
  }

  metricas.registrar(portas.metricas, metricas.MensagensProcessadas)
  case handle_interno(msg, portas) {
    Ok(Nil) -> Ok(Nil)
    Error(e) -> {
      metricas.registrar(portas.metricas, metricas.Erros)
      // Log do erro no servidor
      logging.log(
        logging.Warning,
        "Erro ao processar mensagem de "
          <> msg.remetente
          <> ": "
          <> erro.descricao(e),
      )
      // Tenta enviar mensagem amigável ao usuário
      let _ =
        portas.whatsapp.enviar(
          msg.chat_id,
          "⚠️ Desculpe, ocorreu um erro ao processar sua mensagem. Tente novamente.",
        )
      Error(e)
    }
  }
}

fn handle_interno(msg: Mensagem, portas: Portas) -> Result(Nil, Erro) {
  use cfg <- result.try(portas.config.obter(msg.chat_id))
  use hist <- result.try(portas.historico.obter(msg.chat_id))
  use acoes <- result.try(processador.processar(msg, cfg, hist))
  acoes
  |> list.map(executar_acao(_, msg, cfg, hist, portas))
  |> result.all
  |> result.map(fn(_) { Nil })
}

fn executar_acao(
  acao: acao.Acao,
  msg: Mensagem,
  cfg: config.Config,
  hist: List(Turno),
  portas: Portas,
) -> Result(Nil, Erro) {
  case acao {
    // O core montou o prompt no corpo de EnviarTexto — o shell chama a IA.
    EnviarTexto(para, prompt) -> {
      use resposta <- result.try(ia_dispatcher.gerar_texto(
        portas.ia_dispatcher,
        prompt,
        hist,
        cfg.provedor,
        cfg.modelo,
      ))
      use _ <- result.try(entregar(
        para,
        "amelie",
        "ia_texto",
        resposta,
        msg,
        portas,
      ))
      use _ <- result.try(portas.historico.adicionar(
        msg.chat_id,
        TurnoUsuario(extrair_texto_usuario(msg)),
      ))
      portas.historico.adicionar(msg.chat_id, TurnoAssistente(resposta))
    }

    BuscarUrlEResponder(para, texto, url) -> {
      let prompt = case url_scraper.buscar(url) {
        Ok(conteudo) ->
          builder.montar_com_url(texto, url, conteudo, cfg, hist)
        Error(_) -> builder.montar(texto, cfg, hist)
      }
      use resposta <- result.try(ia_dispatcher.gerar_texto(
        portas.ia_dispatcher,
        prompt,
        hist,
        cfg.provedor,
        cfg.modelo,
      ))
      use _ <- result.try(entregar(para, "amelie", "ia_texto", resposta, msg, portas))
      use _ <- result.try(portas.historico.adicionar(
        msg.chat_id,
        TurnoUsuario(extrair_texto_usuario(msg)),
      ))
      portas.historico.adicionar(msg.chat_id, TurnoAssistente(resposta))
    }

    EnviarResposta(para, corpo) -> {
      entregar(para, "amelie", "texto", corpo, msg, portas)
    }

    EnviarReacao(para, emoji) ->
      entrega_auditada.enviar(
        para,
        "amelie",
        "reacao",
        emoji,
        portas.whatsapp,
        portas.transacoes,
      )

    SalvarConfig(nova_cfg) -> portas.config.salvar(nova_cfg)

    LimparHistorico(chat_id) -> portas.historico.limpar(chat_id)

    EnfileirarMidia(chat_id, tipo) -> {
      logging.log(
        logging.Info,
        "Enfileirando mídia para processamento no chat " <> chat_id,
      )
      let ia_porta =
        ia_dispatcher.como_porta(ia_dispatcher.IADispatcherPorta(
          dispatcher: portas.ia_dispatcher,
          provedor: cfg.provedor,
          modelo: cfg.modelo,
        ))
      fila_midia.enfileirar(
        portas.fila,
        chat_id,
        msg,
        tipo,
        cfg,
        ia_porta,
        portas.whatsapp,
        portas.transacoes,
      )
    }

    SalvarPrompt(chat_id, nome, texto) ->
      portas.prompts.definir(chat_id, nome, texto)

    ExcluirPrompt(chat_id, nome) -> portas.prompts.excluir(chat_id, nome)

    AtivarPrompt(chat_id, nome) -> {
      use maybe_texto <- result.try(portas.prompts.obter(chat_id, nome))
      case maybe_texto {
        option.Some(texto) -> {
          let nova = config.Config(..cfg, prompt_sistema: option.Some(texto))
          use _ <- result.try(portas.config.salvar(nova))
          entrega_auditada.enviar(
            chat_id,
            "amelie",
            "texto",
            "Prompt `" <> nome <> "` ativado.",
            portas.whatsapp,
            portas.transacoes,
          )
        }
        option.None ->
          entrega_auditada.enviar(
            chat_id,
            "amelie",
            "texto",
            "Prompt `" <> nome <> "` não encontrado.",
            portas.whatsapp,
            portas.transacoes,
          )
      }
    }

    ListarPrompts(chat_id) -> {
      use nomes <- result.try(portas.prompts.listar(chat_id))
      let texto = case nomes {
        [] -> "Nenhum prompt salvo."
        _ ->
          "*Prompts salvos:*\n\n"
          <> string.join(list.map(nomes, fn(n) { "- `" <> n <> "`" }), "\n")
      }
      entrega_auditada.enviar(
        chat_id,
        "amelie",
        "texto",
        texto,
        portas.whatsapp,
        portas.transacoes,
      )
    }

    ConsultarMetricas(chat_id) -> {
      let estado = metricas.consultar(portas.metricas)
      entrega_auditada.enviar(
        chat_id,
        "amelie",
        "texto",
        metricas.formatar(estado),
        portas.whatsapp,
        portas.transacoes,
      )
    }

    ListarUsuarios(chat_id) -> {
      let msg_users = case portas.usuarios.listar() {
        Ok(usrs) -> "👥 Usuários ativos:\n" <> string.join(usrs, "\n")
        Error(_) -> "Vazio ou Erro"
      }
      entrega_auditada.enviar(
        chat_id,
        "amelie",
        "texto",
        msg_users,
        portas.whatsapp,
        portas.transacoes,
      )
    }

    ListarGrupos(chat_id) -> {
      let msg_grupos = case portas.grupos.listar() {
        Ok(grps) -> "👥 Grupos ativos:\n" <> string.join(grps, "\n")
        Error(_) -> "Vazio ou Erro"
      }
      entrega_auditada.enviar(
        chat_id,
        "amelie",
        "texto",
        msg_grupos,
        portas.whatsapp,
        portas.transacoes,
      )
    }

    SnapshotHistorico(chat_id) -> {
      logging.log(
        logging.Info,
        "Fazendo snapshot do histórico do chat " <> chat_id,
      )
      use hist <- result.try(portas.historico.obter(chat_id))

      case list.length(hist) > 50 {
        True -> {
          let prompt =
            "Resuma esta conversa de forma concisa, mantendo os pontos importantes:"
          let historia_texto =
            hist
            |> list.map(fn(t) {
              case t {
                TurnoUsuario(c) -> "Usuário: " <> c
                TurnoAssistente(c) -> "Assistente: " <> c
              }
            })
            |> string.join("\n")

          use resumo <- result.try(ia_dispatcher.gerar_texto(
            portas.ia_dispatcher,
            prompt <> "\n\n" <> historia_texto,
            [],
            "gemini",
            "gemini-2.5-flash-lite",
          ))

          use _ <- result.try(portas.historico.limpar(chat_id))
          use _ <- result.try(portas.historico.adicionar(
            chat_id,
            TurnoUsuario(resumo),
          ))

          entrega_auditada.enviar(
            chat_id,
            "amelie",
            "texto",
            "🗃️ Histórico compactado com sucesso!",
            portas.whatsapp,
            portas.transacoes,
          )
        }
        False -> {
          entrega_auditada.enviar(
            chat_id,
            "amelie",
            "texto",
            "📊 Histórico não precisa de compactação ("
              <> int.to_string(list.length(hist))
              <> " mensagens).",
            portas.whatsapp,
            portas.transacoes,
          )
        }
      }
    }

    AlterarModelo(chat_id, provedor, modelo) -> {
      case
        providers_config.validar_modelo(portas.providers_config, provedor, modelo)
      {
        Ok(_) -> {
          let nova = config.Config(..cfg, provedor: provedor, modelo: modelo)
          use _ <- result.try(portas.config.salvar(nova))
          entregar(
            chat_id,
            "amelie",
            "texto",
            "Modelo alterado: `" <> provedor <> "/" <> modelo <> "`",
            msg,
            portas,
          )
        }
        Error(e) ->
          entregar(
            chat_id,
            "amelie",
            "texto",
            "❌ " <> erro.descricao(e),
            msg,
            portas,
          )
      }
    }

    NaoResponder -> Ok(Nil)
  }
}

// Envia citando a mensagem original quando possível; cai em envio simples caso contrário.
fn entregar(
  para: String,
  remetente: String,
  tipo: String,
  conteudo: String,
  msg: Mensagem,
  portas: Portas,
) -> Result(Nil, Erro) {
  case msg.message_id {
    option.Some(mid) ->
      entrega_auditada.enviar_citando(
        para,
        remetente,
        tipo,
        conteudo,
        mid,
        msg.remetente,
        portas.whatsapp,
        portas.transacoes,
      )
    option.None ->
      entrega_auditada.enviar(
        para,
        remetente,
        tipo,
        conteudo,
        portas.whatsapp,
        portas.transacoes,
      )
  }
}

fn extrair_texto_usuario(msg: Mensagem) -> String {
  case msg.corpo {
    Texto(body) -> body
    Imagem(..) -> "[imagem]"
    Audio(..) -> "[áudio]"
    Video(..) -> "[vídeo]"
    Documento(nome: nome, ..) -> "[documento: " <> nome <> "]"
    mensagem.Comando(nome, args) -> "." <> nome <> " " <> args
  }
}
