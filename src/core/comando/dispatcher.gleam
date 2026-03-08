// Despacha comandos. Puro — retorna Acao, não executa efeitos.

import dominio/acao.{type Acao, EnviarResposta, LimparHistorico, SalvarConfig}
import dominio/config.{type Config, Config, Curto, Longo}
import dominio/erro.{type Erro}
import gleam/int
import gleam/option.{None, Some}
import gleam/string

pub fn executar(
  nome: String,
  args: String,
  config: Config,
) -> Result(List(Acao), Erro) {
  case nome {
    "ajuda" -> Ok(ajuda(config))
    "config" -> config_cmd(args, config)
    "reset" -> Ok(reset(config))
    "audio" -> toggle("audio", args, config)
    "imagem" -> toggle("imagem", args, config)
    "video" -> toggle("video", args, config)
    "doc" -> toggle("doc", args, config)
    "legenda" -> toggle("legenda", args, config)
    "longo" -> Ok(modo_descricao_cmd(Longo, config))
    "curto" -> Ok(modo_descricao_cmd(Curto, config))
    "prompt" -> prompt_cmd(args, config)
    "filas" -> Ok(status_filas(config))
    "users" -> Ok(users_cmd(config))
    "grupos" -> Ok(grupos_cmd(config))
    "cego" -> Ok(cego_cmd(config))
    outro -> Error(erro.ErroComandoDesconhecido(outro))
  }
}

fn ajuda(cfg: Config) -> List(Acao) {
  let texto =
    "*Amélie — Comandos disponíveis*\n\n"
    <> "`.ajuda` — esta mensagem\n"
    <> "`.config` — ver configuração atual\n"
    <> "`.reset` — resetar histórico e configurações\n"
    <> "`.audio on|off` — ativar/desativar transcrição de áudio\n"
    <> "`.imagem on|off` — ativar/desativar análise de imagem\n"
    <> "`.video on|off` — ativar/desativar análise de vídeo\n"
    <> "`.doc on|off` — ativar/desativar análise de documento\n"
    <> "`.legenda on|off` — ativar/desativar legenda de vídeo\n"
    <> "`.longo` — usar descrição detalhada\n"
    <> "`.curto` — usar descrição concisa\n"
    <> "`.prompts` — listar comandos de prompt\n"
    <> "`.cego` — modo acessibilidade para deficientes visuais\n"
    <> "`.filas` — status das filas de mídia\n"
    <> "`.users` — usuários ativos\n"
    <> "`.grupos` — grupos ativos"
  [EnviarResposta(para: cfg.chat_id, corpo: texto)]
}

fn config_cmd(args: String, cfg: Config) -> Result(List(Acao), Erro) {
  case string.trim(args) {
    "" -> Ok([EnviarResposta(cfg.chat_id, formatar_config(cfg))])
    _ -> Error(erro.ErroValidacao("config", "argumento inválido"))
  }
}

fn reset(cfg: Config) -> List(Acao) {
  [
    SalvarConfig(config.padrao(cfg.chat_id)),
    LimparHistorico(cfg.chat_id),
    EnviarResposta(
      cfg.chat_id,
      "Histórico e configurações resetados. Podemos começar uma nova conversa.",
    ),
  ]
}

fn toggle(
  recurso: String,
  args: String,
  cfg: Config,
) -> Result(List(Acao), Erro) {
  case string.trim(string.lowercase(args)) {
    "on" -> {
      let nova = aplicar_toggle(recurso, True, cfg)
      Ok([
        SalvarConfig(nova),
        EnviarResposta(cfg.chat_id, recurso <> " ativado."),
      ])
    }
    "off" -> {
      let nova = aplicar_toggle(recurso, False, cfg)
      Ok([
        SalvarConfig(nova),
        EnviarResposta(cfg.chat_id, recurso <> " desativado."),
      ])
    }
    "" -> {
      let status = case estado_recurso(recurso, cfg) {
        True -> "ativado"
        False -> "desativado"
      }
      Ok([EnviarResposta(cfg.chat_id, recurso <> " está " <> status <> ".")])
    }
    outro ->
      Error(erro.ErroValidacao(
        recurso,
        "valor inválido: " <> outro <> ". Use on ou off.",
      ))
  }
}

fn aplicar_toggle(recurso: String, valor: Bool, cfg: Config) -> Config {
  case recurso {
    "audio" -> Config(..cfg, audio_ativo: valor)
    "imagem" -> Config(..cfg, imagem_ativo: valor)
    "video" -> Config(..cfg, video_ativo: valor)
    "doc" -> Config(..cfg, doc_ativo: valor)
    "legenda" -> Config(..cfg, legenda_ativo: valor)
    _ -> cfg
  }
}

fn estado_recurso(recurso: String, cfg: Config) -> Bool {
  case recurso {
    "audio" -> cfg.audio_ativo
    "imagem" -> cfg.imagem_ativo
    "video" -> cfg.video_ativo
    "doc" -> cfg.doc_ativo
    "legenda" -> cfg.legenda_ativo
    _ -> False
  }
}

fn modo_descricao_cmd(modo: config.ModoDescricao, cfg: Config) -> List(Acao) {
  let nova = Config(..cfg, modo_descricao: modo)
  let label = config.modo_para_string(modo)
  [
    SalvarConfig(nova),
    EnviarResposta(cfg.chat_id, "Modo de descrição: " <> label <> "."),
  ]
}

fn prompt_cmd(args: String, cfg: Config) -> Result(List(Acao), Erro) {
  case string.trim(args) {
    "" ->
      Ok([
        EnviarResposta(cfg.chat_id, case cfg.prompt_sistema {
          Some(p) -> "Prompt atual:\n\n" <> p
          None -> "Nenhum prompt personalizado definido."
        }),
      ])
    "reset" -> {
      let nova = Config(..cfg, prompt_sistema: None)
      Ok([
        SalvarConfig(nova),
        EnviarResposta(cfg.chat_id, "Prompt personalizado removido."),
      ])
    }
    "listar" -> Ok([acao.ListarPrompts(cfg.chat_id)])
    input -> {
      case string.split_once(input, " ") {
        Ok(#("novo", rest)) -> {
          case string.split_once(string.trim(rest), " ") {
            Ok(#(nome, texto)) ->
              Ok([
                acao.SalvarPrompt(cfg.chat_id, nome, string.trim(texto)),
                EnviarResposta(cfg.chat_id, "Prompt `" <> nome <> "` salvo."),
              ])
            Error(_) ->
              Error(erro.ErroValidacao(
                "prompt",
                "Use: .prompt novo <nome> <texto>",
              ))
          }
        }
        Ok(#("ativar", nome)) -> {
          let nome_trim = string.trim(nome)
          Ok([acao.AtivarPrompt(cfg.chat_id, nome_trim)])
        }
        Ok(#("excluir", nome)) -> {
          let nome_trim = string.trim(nome)
          Ok([
            acao.ExcluirPrompt(cfg.chat_id, nome_trim),
            EnviarResposta(
              cfg.chat_id,
              "Prompt `" <> nome_trim <> "` excluído.",
            ),
          ])
        }
        _ -> {
          // Backward compat: .prompt <texto> sets inline prompt
          let nova = Config(..cfg, prompt_sistema: Some(input))
          Ok([
            SalvarConfig(nova),
            EnviarResposta(cfg.chat_id, "Prompt personalizado definido."),
          ])
        }
      }
    }
  }
}

fn cego_cmd(cfg: Config) -> List(Acao) {
  let prompt_cego =
    "Você é Amélie, assistente de acessibilidade para usuários com deficiência visual. "
    <> "Descreva imagens com riqueza de detalhes: cores, posições espaciais, textos visíveis, "
    <> "expressões faciais, ações e contexto geral. Seja precisa e use linguagem clara."
  let nova =
    Config(
      ..cfg,
      imagem_ativo: True,
      audio_ativo: False,
      prompt_sistema: Some(prompt_cego),
      modo_descricao: Longo,
    )
  [
    SalvarConfig(nova),
    EnviarResposta(
      cfg.chat_id,
      "Configurações para deficiência visual aplicadas:\n"
        <> "- Análise de imagens: ativada\n"
        <> "- Transcrição de áudio: desativada\n"
        <> "- Modo de descrição: longo\n"
        <> "- Prompt de descrição detalhada: ativo",
    ),
  ]
}

fn status_filas(cfg: Config) -> List(Acao) {
  [acao.ConsultarMetricas(cfg.chat_id)]
}

fn users_cmd(cfg: Config) -> List(Acao) {
  [acao.ListarUsuarios(cfg.chat_id)]
}

fn grupos_cmd(cfg: Config) -> List(Acao) {
  [acao.ListarGrupos(cfg.chat_id)]
}

fn formatar_config(cfg: Config) -> String {
  "*Configuração atual*\n\n"
  <> "Modelo: `"
  <> cfg.modelo
  <> "`\n"
  <> "Histórico: `"
  <> int.to_string(cfg.historico_max)
  <> " turnos`\n"
  <> "Áudio: `"
  <> bool_str(cfg.audio_ativo)
  <> "`\n"
  <> "Imagem: `"
  <> bool_str(cfg.imagem_ativo)
  <> "`\n"
  <> "Vídeo: `"
  <> bool_str(cfg.video_ativo)
  <> "`\n"
  <> "Documento: `"
  <> bool_str(cfg.doc_ativo)
  <> "`\n"
  <> "Legenda: `"
  <> bool_str(cfg.legenda_ativo)
  <> "`\n"
  <> "Modo: `"
  <> config.modo_para_string(cfg.modo_descricao)
  <> "`\n"
  <> "Idioma: `"
  <> cfg.idioma
  <> "`\n"
  <> case cfg.prompt_sistema {
    Some(_) -> "Prompt: `personalizado`"
    None -> "Prompt: `padrão`"
  }
}

fn bool_str(b: Bool) -> String {
  case b {
    True -> "on"
    False -> "off"
  }
}
