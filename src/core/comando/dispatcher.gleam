// Despacha comandos. Puro — retorna Acao, não executa efeitos.

import dominio/acao.{type Acao, EnviarTexto, NaoResponder}
import dominio/config.{type Config}
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
    "prompt" -> prompt_cmd(args, config)
    "filas" -> Ok(status_filas(config))
    "users" -> Ok(users_cmd(config))
    "cego" -> Ok(cego_cmd(config))
    outro -> Error(erro.ErroComandoDesconhecido(outro))
  }
}

fn ajuda(config: Config) -> List(Acao) {
  let texto =
    "*Amélie — Comandos disponíveis*\n\n"
    <> "`.ajuda` — esta mensagem\n"
    <> "`.config` — ver configuração atual\n"
    <> "`.reset` — resetar histórico\n"
    <> "`.audio on|off` — ativar/desativar transcrição de áudio\n"
    <> "`.imagem on|off` — ativar/desativar análise de imagem\n"
    <> "`.video on|off` — ativar/desativar análise de vídeo\n"
    <> "`.doc on|off` — ativar/desativar análise de documento\n"
    <> "`.prompt <texto>` — definir prompt personalizado\n"
    <> "`.prompt reset` — remover prompt personalizado\n"
    <> "`.filas` — status das filas de mídia\n"
    <> "`.users` — usuários autorizados (grupos)\n"
    <> "`.cego` — modo acessibilidade"
  [EnviarTexto(para: config.chat_id, corpo: texto)]
}

fn config_cmd(args: String, config: Config) -> Result(List(Acao), Erro) {
  case string.trim(args) {
    "" -> Ok([EnviarTexto(config.chat_id, formatar_config(config))])
    _ -> Error(erro.ErroValidacao("config", "argumento inválido"))
  }
}

fn reset(config: Config) -> List(Acao) {
  // O shell detecta NaoResponder após EnviarTexto e limpa o histórico
  [
    EnviarTexto(
      config.chat_id,
      "Histórico limpo. Podemos começar uma nova conversa.",
    ),
  ]
}

fn toggle(
  recurso: String,
  args: String,
  config: Config,
) -> Result(List(Acao), Erro) {
  case string.trim(string.lowercase(args)) {
    "on" | "off" -> Ok([NaoResponder])
    // Shell aplica o toggle lendo o resultado do core
    "" -> {
      let estado = case recurso {
        "audio" -> config.audio_ativo
        "imagem" -> config.imagem_ativo
        "video" -> config.video_ativo
        "doc" -> config.doc_ativo
        _ -> False
      }
      let status = case estado {
        True -> "ativado"
        False -> "desativado"
      }
      Ok([EnviarTexto(config.chat_id, recurso <> " está " <> status)])
    }
    outro ->
      Error(erro.ErroValidacao(
        recurso,
        "valor inválido: " <> outro <> ". Use on ou off.",
      ))
  }
}

fn prompt_cmd(args: String, config: Config) -> Result(List(Acao), Erro) {
  case string.trim(args) {
    "" ->
      Ok([
        EnviarTexto(
          config.chat_id,
          case config.prompt_sistema {
            Some(p) -> "Prompt atual:\n\n" <> p
            None -> "Nenhum prompt personalizado definido."
          },
        ),
      ])
    "reset" ->
      Ok([
        EnviarTexto(
          config.chat_id,
          "Prompt personalizado removido.",
        ),
      ])
    _ -> Ok([NaoResponder])
    // Shell salva o novo prompt
  }
}

fn status_filas(config: Config) -> List(Acao) {
  [
    EnviarTexto(
      config.chat_id,
      "Status das filas disponível via telemetria.",
    ),
  ]
}

fn users_cmd(config: Config) -> List(Acao) {
  [EnviarTexto(config.chat_id, "Funcionalidade de usuários em implementação.")]
}

fn cego_cmd(config: Config) -> List(Acao) {
  [
    EnviarTexto(
      config.chat_id,
      "Modo acessibilidade ativado — todas as mídias serão descritas.",
    ),
  ]
}

fn formatar_config(config: Config) -> String {
  "*Configuração atual*\n\n"
  <> "Modelo: `"
  <> config.modelo
  <> "`\n"
  <> "Histórico: `"
  <> int_to_str(config.historico_max)
  <> " turnos`\n"
  <> "Áudio: `"
  <> bool_str(config.audio_ativo)
  <> "`\n"
  <> "Imagem: `"
  <> bool_str(config.imagem_ativo)
  <> "`\n"
  <> "Vídeo: `"
  <> bool_str(config.video_ativo)
  <> "`\n"
  <> "Documento: `"
  <> bool_str(config.doc_ativo)
  <> "`\n"
  <> "Idioma: `"
  <> config.idioma
  <> "`\n"
  <> case config.prompt_sistema {
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

fn int_to_str(n: Int) -> String {
  int.to_string(n)
}
