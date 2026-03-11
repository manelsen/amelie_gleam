// Despacha comandos. Puro — retorna Acao, não executa efeitos.

import dominio/acao.{type Acao, AlterarModelo, EnviarResposta, LimparHistorico, SalvarConfig}
import dominio/config.{type Config, Config, Curto, Longo}
import dominio/erro.{type Erro}
import gleam/option.{Some}
import gleam/string

pub fn executar(
  nome: String,
  args: String,
  config: Config,
) -> Result(List(Acao), Erro) {
  case nome {
    "ajuda" -> Ok(ajuda(config))
    "reset" -> Ok(reset(config))
    "audio" -> toggle("audio", args, config)
    "imagem" -> toggle("imagem", args, config)
    "video" -> toggle("video", args, config)
    "doc" -> toggle("doc", args, config)
    "legenda" -> Ok(legenda_cmd(config))
    "longo" -> Ok(modo_descricao_cmd(Longo, config))
    "curto" -> Ok(modo_descricao_cmd(Curto, config))
    "cego" -> Ok(cego_cmd(config))
    "modelo" -> Ok(modelo_cmd(args, config))
    outro -> Error(erro.ErroComandoDesconhecido(outro))
  }
}

fn ajuda(cfg: Config) -> List(Acao) {
  let texto =
    "*Amélie — Comandos disponíveis*\n\n"
    <> "`.ajuda` — esta mensagem\n"
    <> "`.reset` — resetar histórico e configurações\n"
    <> "`.audio on|off` — ativar/desativar transcrição de áudio\n"
    <> "`.imagem on|off` — ativar/desativar análise de imagem\n"
    <> "`.video on|off` — ativar/desativar análise de vídeo\n"
    <> "`.doc on|off` — ativar/desativar análise de documento\n"
    <> "`.legenda` — alternar legenda de vídeo\n"
    <> "`.longo` — usar descrição detalhada\n"
    <> "`.curto` — usar descrição concisa\n"
    <> "`.cego` — modo acessibilidade para deficientes visuais\n"
    <> "`.modelo` — mostrar provedor/modelo atual\n"
    <> "`.modelo provedor/modelo` — alterar provedor e modelo"
  [EnviarResposta(para: cfg.chat_id, corpo: texto)]
}

fn modelo_cmd(args: String, cfg: Config) -> List(Acao) {
  case string.trim(args) {
    "" ->
      [
        EnviarResposta(
          cfg.chat_id,
          "Provedor atual: `"
            <> cfg.provedor
            <> "`\nModelo atual: `"
            <> cfg.modelo
            <> "`",
        ),
      ]
    spec ->
      case string.split_once(spec, "/") {
        Ok(#(provedor, modelo)) ->
          [
            AlterarModelo(
              chat_id: cfg.chat_id,
              provedor: string.trim(provedor),
              modelo: string.trim(modelo),
            ),
          ]
        Error(_) ->
          [
            EnviarResposta(
              cfg.chat_id,
              "Formato inválido. Use: `.modelo provedor/modelo`\nEx: `.modelo gemini/gemini-2.5-pro`",
            ),
          ]
      }
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

fn modo_descricao_cmd(modo: config.ModoDescricao, cfg: Config) -> List(Acao) {
  let nova = Config(..cfg, modo_descricao: modo)
  let label = config.modo_para_string(modo)
  [
    SalvarConfig(nova),
    EnviarResposta(cfg.chat_id, "Modo de descrição: " <> label <> "."),
  ]
}

fn legenda_cmd(cfg: Config) -> List(Acao) {
  let nova = Config(..cfg, legenda_ativo: !cfg.legenda_ativo)
  let status = case nova.legenda_ativo {
    True -> "ativada"
    False -> "desativada"
  }
  [SalvarConfig(nova), EnviarResposta(cfg.chat_id, "Legenda " <> status <> ".")]
}

fn cego_cmd(cfg: Config) -> List(Acao) {
  let prompt_cego =
    "Você é Amélie, assistente de acessibilidade para usuários com deficiência visual. "
    <> "Descreva imagens com riqueza de detalhes: cores, posições espaciais, textos visíveis, "
    <> "expressões faciais, ações e contexto geral. Seja preciso e use linguagem clara."
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
