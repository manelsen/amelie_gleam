// Shell — executa os efeitos prescritos pelo core.
// Este módulo tem side effects: chama portas, grava histórico.

import core/processador
import dominio/acao.{
  AtivarPrompt, ConsultarMetricas, EnfileirarMidia, EnviarReacao, EnviarResposta,
  EnviarTexto, ExcluirPrompt, LimparHistorico, ListarGrupos, ListarPrompts,
  ListarUsuarios, NaoResponder, SalvarConfig, SalvarPrompt,
}
import dominio/config
import dominio/erro.{type Erro}
import dominio/mensagem.{
  type Mensagem, type Turno, Audio, Documento, Imagem, Texto, TurnoAssistente,
  TurnoUsuario, Video,
}
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import logging
import portas/config_porta.{type ConfigPorta}
import portas/grupo_porta.{type GrupoPorta}
import portas/historico_porta.{type HistoricoPorta}
import portas/ia_porta.{type IAPorta}
import portas/prompt_porta.{type PromptPorta}
import portas/usuario_porta.{type UsuarioPorta}
import portas/whatsapp_porta.{type WhatsappPorta}
import shell/fila_midia.{type FilasMidia}
import shell/metricas.{type Metricas}

pub type Portas {
  Portas(
    whatsapp: WhatsappPorta,
    ia: IAPorta,
    config: ConfigPorta,
    historico: HistoricoPorta,
    fila: FilasMidia,
    prompts: PromptPorta,
    metricas: Metricas,
    usuarios: UsuarioPorta,
    grupos: GrupoPorta,
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
      logging.log(logging.Info, "Enviando texto gerado pela IA para " <> para)
      use resposta <- result.try(portas.ia.gerar_texto(prompt, hist, cfg.modelo))
      use _ <- result.try(portas.whatsapp.enviar(para, resposta))
      use _ <- result.try(portas.historico.adicionar(
        msg.chat_id,
        TurnoUsuario(extrair_texto_usuario(msg)),
      ))
      portas.historico.adicionar(msg.chat_id, TurnoAssistente(resposta))
    }

    EnviarResposta(para, corpo) -> {
      logging.log(logging.Info, "Enviando resposta direta para " <> para)
      portas.whatsapp.enviar(para, corpo)
    }

    EnviarReacao(para, emoji) -> portas.whatsapp.enviar(para, emoji)

    SalvarConfig(nova_cfg) -> portas.config.salvar(nova_cfg)

    LimparHistorico(chat_id) -> portas.historico.limpar(chat_id)

    EnfileirarMidia(chat_id, tipo) -> {
      logging.log(
        logging.Info,
        "Enfileirando mídia para processamento no chat " <> chat_id,
      )
      fila_midia.enfileirar(
        portas.fila,
        chat_id,
        msg,
        tipo,
        cfg,
        portas.ia,
        portas.whatsapp,
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
          portas.whatsapp.enviar(chat_id, "Prompt `" <> nome <> "` ativado.")
        }
        option.None ->
          portas.whatsapp.enviar(
            chat_id,
            "Prompt `" <> nome <> "` não encontrado.",
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
      portas.whatsapp.enviar(chat_id, texto)
    }

    ConsultarMetricas(chat_id) -> {
      let estado = metricas.consultar(portas.metricas)
      portas.whatsapp.enviar(chat_id, metricas.formatar(estado))
    }

    ListarUsuarios(chat_id) -> {
      use _usuarios <- result.try(portas.usuarios.listar())
      use _contagem <- result.try(portas.usuarios.contar())
      let msg_users = case portas.usuarios.listar() {
        Ok(usrs) -> "👥 Usuários ativos:\n" <> string.join(usrs, "\n")
        Error(_) -> "Vazio ou Erro"
      }
      portas.whatsapp.enviar(chat_id, msg_users)
    }

    ListarGrupos(chat_id) -> {
      let msg_grupos = case portas.grupos.listar() {
        Ok(grps) -> "👥 Grupos ativos:\n" <> string.join(grps, "\n")
        Error(_) -> "Vazio ou Erro"
      }
      portas.whatsapp.enviar(chat_id, msg_grupos)
    }

    NaoResponder -> Ok(Nil)
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
