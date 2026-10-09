// Shell — executa os efeitos prescritos pelo core.
// Este módulo tem side effects: chama portas, grava histórico.

import adaptadores/whatsmeow_http
import core/acessibilidade
import core/ia_dispatcher
import core/processador
import core/prompt/builder
import dominio/acao.{
  AlterarModelo, AtivarPrompt, BaixarVideoUrlEDescrever, BuscarUrlEResponder,
  ConsultarMetricas, ConsultarStatus, EnfileirarMidia, EnviarReacao,
  EnviarResposta, ExcluirPrompt, GerarEEnviar, LimparHistorico, ListarGrupos,
  ListarPrompts, ListarUsuarios, MidiaVideo, NaoResponder, ResetarWhatsApp,
  SalvarConfig, SalvarPrompt, SnapshotHistorico, SolicitarPareamento,
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
import portas/mensageiro_porta.{type MensageiroPorta}
import portas/prompt_porta.{type PromptPorta}
import portas/transacao_porta.{type TransacaoPorta}
import portas/usuario_porta.{type UsuarioPorta}
import shell/arquivos_temporarios
import shell/entrega_auditada
import shell/fila_midia.{type FilasMidia}
import shell/metricas.{type Metricas}
import shell/url_scraper
import shell/ytdlp

@external(erlang, "amelie_gleam_ffi", "now_ms")
fn now_ms() -> Int

@external(erlang, "amelie_gleam_ffi", "spawn_fn")
fn spawn_fn(f: fn() -> a) -> Nil

@external(erlang, "amelie_gleam_ffi", "get_env")
fn get_env(name: String) -> Result(String, Nil)

pub type Portas {
  Portas(
    mensageiro: MensageiroPorta,
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

pub fn extrair_trace_id(msg: Mensagem) -> String {
  case msg.message_id {
    option.Some(id) if id != "" -> id
    _ -> "req_" <> int.to_string(msg.timestamp) <> "_" <> msg.remetente
  }
}

pub fn handle(msg: Mensagem, portas: Portas) -> Result(Nil, Erro) {
  let trace_id = extrair_trace_id(msg)
  logging.log(
    logging.Info,
    "[trace:"
      <> trace_id
      <> "] Mensagem recebida do chat "
      <> msg.chat_id
      <> " (remetente: "
      <> msg.remetente
      <> ")",
  )

  // Filtro de idade: rejeita mensagens com mais de 48h.
  // O history sync do WhatsApp reenvia o histórico completo ao reconectar —
  // sem este filtro, mensagens já respondidas seriam reprocessadas após
  // um reinício ou recriação do banco de dados.
  let agora_s = now_ms() / 1000
  case msg.timestamp > 0 && agora_s - msg.timestamp > 48 * 60 * 60 {
    True -> {
      logging.log(
        logging.Info,
        "[trace:"
          <> trace_id
          <> "] Mensagem ignorada por ser muito antiga (ts="
          <> int.to_string(msg.timestamp)
          <> "): "
          <> msg.chat_id,
      )
      limpar_midia_se_descartada(msg)
      Ok(Nil)
    }
    False ->
      // Deduplicação: history sync pode reenviar mensagens já processadas.
      // Mensagens sem message_id (raro) são sempre processadas.
      case msg.message_id {
        option.Some(msg_id) -> {
          case portas.transacoes.foi_recebida(msg_id) {
            Ok(True) -> {
              logging.log(
                logging.Info,
                "[trace:"
                  <> trace_id
                  <> "] Mensagem ja processada, ignorando: "
                  <> msg_id,
              )
              limpar_midia_se_descartada(msg)
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
    "[trace:" <> trace_id <> "] Processando mensagem: " <> msg.chat_id,
  )

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
      limpar_midia_se_descartada(msg)
      metricas.registrar(portas.metricas, metricas.Erros)
      // Log do erro no servidor
      logging.log(
        logging.Warning,
        "[trace:"
          <> trace_id
          <> "] Erro ao processar mensagem de "
          <> msg.remetente
          <> ": "
          <> erro.descricao(e),
      )
      // Tenta enviar mensagem amigável ao usuário
      let _ =
        portas.mensageiro.enviar(
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
    GerarEEnviar(para, prompt) -> {
      let trace_id = extrair_trace_id(msg)
      logging.log(
        logging.Info,
        "[trace:" <> trace_id <> "] Enviando texto gerado pela IA para " <> para,
      )
      use resposta <- result.try(ia_dispatcher.gerar_texto(
        portas.ia_dispatcher,
        prompt,
        hist,
        cfg.provedor,
        cfg.modelo,
      ))
      let resposta_limpa = acessibilidade.sanitizar_saida_voz(resposta)
      use _ <- result.try(entregar(
        para,
        "amelie",
        "ia_texto",
        resposta_limpa,
        msg,
        portas,
      ))
      use _ <- result.try(portas.historico.adicionar(
        msg.chat_id,
        TurnoUsuario(extrair_texto_usuario(msg)),
      ))
      portas.historico.adicionar(msg.chat_id, TurnoAssistente(resposta_limpa))
    }

    BuscarUrlEResponder(para, texto, url) -> {
      let prompt = case url_scraper.buscar(url) {
        Ok(conteudo) -> builder.montar_com_url(texto, url, conteudo, cfg, hist)
        Error(_) -> builder.montar(texto, cfg, hist)
      }
      use resposta <- result.try(ia_dispatcher.gerar_texto(
        portas.ia_dispatcher,
        prompt,
        hist,
        cfg.provedor,
        cfg.modelo,
      ))
      let resposta_limpa = acessibilidade.sanitizar_saida_voz(resposta)
      use _ <- result.try(entregar(
        para,
        "amelie",
        "ia_texto",
        resposta_limpa,
        msg,
        portas,
      ))
      use _ <- result.try(portas.historico.adicionar(
        msg.chat_id,
        TurnoUsuario(extrair_texto_usuario(msg)),
      ))
      portas.historico.adicionar(msg.chat_id, TurnoAssistente(resposta_limpa))
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
        portas.mensageiro,
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
        portas.mensageiro,
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
            portas.mensageiro,
            portas.transacoes,
          )
        }
        option.None ->
          entrega_auditada.enviar(
            chat_id,
            "amelie",
            "texto",
            "Prompt `" <> nome <> "` não encontrado.",
            portas.mensageiro,
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
        portas.mensageiro,
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
        portas.mensageiro,
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
        portas.mensageiro,
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
        portas.mensageiro,
        portas.transacoes,
      )
    }

    SnapshotHistorico(chat_id) -> {
      logging.log(
        logging.Info,
        "Fazendo snapshot e resumo do histórico do chat " <> chat_id,
      )
      use hist <- result.try(portas.historico.obter(chat_id))

      case list.length(hist) < 2 {
        True -> {
          entrega_auditada.enviar(
            chat_id,
            "amelie",
            "texto",
            "Ainda não há mensagens suficientes no histórico para gerar um resumo.",
            portas.mensageiro,
            portas.transacoes,
          )
        }
        False -> {
          let prompt =
            "Resuma esta conversa de forma concisa e acessível, destacando os pontos principais, decisões e tópicos discutidos:\n\n"
          let historia_texto =
            hist
            |> list.map(fn(t) {
              case t {
                TurnoUsuario(c) -> "Usuário: " <> c
                TurnoAssistente(c) -> "Amélie: " <> c
              }
            })
            |> string.join("\n")

          use resumo <- result.try(ia_dispatcher.gerar_texto(
            portas.ia_dispatcher,
            prompt <> historia_texto,
            [],
            cfg.provedor,
            cfg.modelo,
          ))

          let resumo_limpo = acessibilidade.sanitizar_saida_voz(resumo)

          // Compacta no banco se houver 10 ou mais turnos acumulados
          use _ <- result.try(case list.length(hist) >= 10 {
            True -> {
              use _ <- result.try(portas.historico.limpar(chat_id))
              portas.historico.adicionar(
                chat_id,
                TurnoUsuario("Contexto anterior resumido: " <> resumo_limpo),
              )
            }
            False -> Ok(Nil)
          })

          entrega_auditada.enviar(
            chat_id,
            "amelie",
            "texto",
            "📝 *Resumo da conversa:*\n\n" <> resumo_limpo,
            portas.mensageiro,
            portas.transacoes,
          )
        }
      }
    }

    AlterarModelo(chat_id, provedor, modelo) -> {
      case
        providers_config.validar_modelo(
          portas.providers_config,
          provedor,
          modelo,
        )
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

    BaixarVideoUrlEDescrever(chat_id, url) -> {
      case msg.message_id {
        option.Some(mid) -> {
          let _ = portas.mensageiro.reagir(chat_id, mid, msg.remetente, "⌛")
          Nil
        }
        option.None -> Nil
      }
      let ia_porta =
        ia_dispatcher.como_porta(ia_dispatcher.IADispatcherPorta(
          dispatcher: portas.ia_dispatcher,
          provedor: cfg.provedor,
          modelo: cfg.modelo,
        ))
      let _ =
        spawn_fn(fn() {
          case ytdlp.baixar(url) {
            Error(e) -> {
              logging.log(
                logging.Warning,
                "[YtDlp] Falha em " <> url <> ": " <> erro.descricao(e),
              )
              let _ =
                portas.mensageiro.enviar(
                  chat_id,
                  "O download de links de vídeo está desativado. Envie o arquivo de vídeo diretamente.",
                )
              Nil
            }
            Ok(caminho) -> {
              let msg_video =
                mensagem.Mensagem(
                  ..msg,
                  corpo: mensagem.Video(
                    caminho_temp: caminho,
                    mime: "video/mp4",
                  ),
                )
              let _ =
                fila_midia.enfileirar(
                  portas.fila,
                  chat_id,
                  msg_video,
                  MidiaVideo,
                  cfg,
                  ia_porta,
                  portas.mensageiro,
                  portas.transacoes,
                )
              Nil
            }
          }
        })
      Ok(Nil)
    }

    SolicitarPareamento(chat_id, args) -> {
      let admin_id =
        get_env("TELEGRAM_ADMIN_CHAT_ID")
        |> result.unwrap(or: "")
      let eh_admin =
        admin_id != ""
        && !msg.em_grupo
        && msg.remetente == "tg:" <> admin_id
        && msg.chat_id == "tg:" <> admin_id
      case eh_admin {
        False -> {
          let _ =
            portas.mensageiro.enviar(
              chat_id,
              "⛔ Comando restrito ao administrador.",
            )
          Ok(Nil)
        }
        True -> {
          let bridge_url =
            get_env("WHATSMEOW_URL")
            |> result.unwrap(or: "http://localhost:8080")
          case whatsmeow_http.checar_status(bridge_url) {
            Ok(whatsmeow_http.StatusBridge(_, True)) -> {
              let _ =
                portas.mensageiro.enviar(
                  chat_id,
                  "✅ O WhatsApp já está conectado e funcionando perfeitamente!",
                )
              Ok(Nil)
            }
            _ -> {
              let tel = case string.trim(args) {
                "" ->
                  get_env("MOBILE_NUMBER")
                  |> result.unwrap(or: "")
                outro -> outro
              }
              case tel {
                "" -> {
                  let _ =
                    portas.mensageiro.enviar(
                      chat_id,
                      "⚠️ WhatsApp desconectado. Por favor, informe seu número com DDD.\nEx: `/parear 5531999990000`",
                    )
                  Ok(Nil)
                }
                numero -> {
                  case whatsmeow_http.pedir_pairing_code(bridge_url, numero) {
                    Ok(code) -> {
                      let texto =
                        "📱 *Código de pareamento gerado:*\n`"
                        <> code
                        <> "` (para +"
                        <> numero
                        <> ")\n\n"
                        <> "👉 *No WhatsApp do seu celular:*\n"
                        <> "Aparelhos conectados > Conectar com número de telefone > Digite o código."
                      let _ = portas.mensageiro.enviar(chat_id, texto)
                      Ok(Nil)
                    }
                    Error(motivo) -> {
                      let _ =
                        portas.mensageiro.enviar(
                          chat_id,
                          "❌ Falha ao gerar pairing code: " <> motivo,
                        )
                      Ok(Nil)
                    }
                  }
                }
              }
            }
          }
        }
      }
    }

    ConsultarStatus(chat_id) -> {
      let admin_id =
        get_env("TELEGRAM_ADMIN_CHAT_ID")
        |> result.unwrap(or: "")
      let eh_admin =
        admin_id != ""
        && !msg.em_grupo
        && msg.remetente == "tg:" <> admin_id
        && msg.chat_id == "tg:" <> admin_id
      case eh_admin {
        False -> {
          let _ =
            portas.mensageiro.enviar(
              chat_id,
              "⛔ Comando restrito ao administrador.",
            )
          Ok(Nil)
        }
        True -> {
          let bridge_url =
            get_env("WHATSMEOW_URL")
            |> result.unwrap(or: "http://localhost:8080")
          let status_wa = case whatsmeow_http.checar_status(bridge_url) {
            Ok(whatsmeow_http.StatusBridge(_, True)) -> "🟢 Conectado"
            Ok(whatsmeow_http.StatusBridge(_, False)) ->
              "🟡 Desconectado (aguardando login)"
            Error(_) -> "🔴 Inacessível"
          }
          let mem_total = metricas.memoria_total_mb()
          let mem_proc = metricas.memoria_processos_mb()
          let proc_count = metricas.contagem_processos()
          let estado_metricas = metricas.consultar(portas.metricas)
          let total_midias =
            estado_metricas.imagens
            + estado_metricas.audios
            + estado_metricas.videos
            + estado_metricas.documentos
            + estado_metricas.stickers

          let corpo =
            "📊 *Painel Administrativo — Amélie*\n\n"
            <> "*Canais de Mensageria:*\n"
            <> "• *WhatsApp:* "
            <> status_wa
            <> "\n"
            <> "• *Telegram:* 🟢 Ativo (Poller operacional)\n\n"
            <> "*Métricas BEAM:*\n"
            <> "• Memória total: `"
            <> int.to_string(mem_total)
            <> " MB`\n"
            <> "• Memória processos: `"
            <> int.to_string(mem_proc)
            <> " MB`\n"
            <> "• Processos OTP: `"
            <> int.to_string(proc_count)
            <> "`\n\n"
            <> "*Mensagens & Mídia:*\n"
            <> "• Mensagens processadas: `"
            <> int.to_string(estado_metricas.mensagens)
            <> "`\n"
            <> "• Erros registrados: `"
            <> int.to_string(estado_metricas.erros)
            <> "`\n"
            <> "• Mídias processadas: `"
            <> int.to_string(total_midias)
            <> "`"
          let _ = portas.mensageiro.enviar(chat_id, corpo)
          Ok(Nil)
        }
      }
    }

    ResetarWhatsApp(chat_id, args) -> {
      let admin_id =
        get_env("TELEGRAM_ADMIN_CHAT_ID")
        |> result.unwrap(or: "")
      let eh_admin =
        admin_id != ""
        && !msg.em_grupo
        && msg.remetente == "tg:" <> admin_id
        && msg.chat_id == "tg:" <> admin_id
      case eh_admin {
        False -> {
          let _ =
            portas.mensageiro.enviar(
              chat_id,
              "⛔ Comando restrito ao administrador.",
            )
          Ok(Nil)
        }
        True -> {
          let bridge_url =
            get_env("WHATSMEOW_URL")
            |> result.unwrap(or: "http://localhost:8080")
          let tel = case string.trim(args) {
            "" ->
              get_env("MOBILE_NUMBER")
              |> result.unwrap(or: "")
            outro -> outro
          }
          case whatsmeow_http.resetar_sessao(bridge_url, tel) {
            Ok(Nil) -> {
              let msg_ret = case tel {
                "" ->
                  "🔄 *Reset do WhatsApp iniciado!*\n\nSessão anterior desconectada e dados locais limpos.\nPara parear um novo celular, execute: `/parear <telefone>`"
                num ->
                  "🔄 *Reset do WhatsApp iniciado!*\n\nSessão anterior desconectada e dados locais limpos para o número `+"
                  <> num
                  <> "`.\nUm novo código de pareamento será enviado aqui em instantes."
              }
              let _ = portas.mensageiro.enviar(chat_id, msg_ret)
              Ok(Nil)
            }
            Error(motivo) -> {
              let _ =
                portas.mensageiro.enviar(
                  chat_id,
                  "❌ Falha ao solicitar reset do WhatsApp: " <> motivo,
                )
              Ok(Nil)
            }
          }
        }
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
  let conteudo_sanitizado = acessibilidade.sanitizar_saida_voz(conteudo)
  case msg.message_id {
    option.Some(mid) ->
      entrega_auditada.enviar_citando(
        para,
        remetente,
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
        remetente,
        tipo,
        conteudo_sanitizado,
        portas.mensageiro,
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
    mensagem.Sticker(..) -> "[sticker]"
    mensagem.MidiaIndisponivel(..) -> "[mídia indisponível]"
    mensagem.Comando(nome, args) -> "." <> nome <> " " <> args
  }
}
