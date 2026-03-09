// O core não executa efeitos — prescreve Acoes.
// O shell as executa.

import dominio/config.{type Config}

pub type Acao {
  // Passa `corpo` como prompt para a IA; shell envia a resposta gerada.
  // Usado para mensagens de texto do usuário.
  EnviarTexto(para: String, corpo: String)
  // Envia `corpo` diretamente ao WhatsApp, sem chamar a IA.
  // Usado para respostas de comandos.
  EnviarResposta(para: String, corpo: String)
  EnviarReacao(para: String, emoji: String)
  EnfileirarMidia(chat_id: String, tipo: TipoMidia)
  SalvarConfig(config: Config)
  LimparHistorico(chat_id: String)
  // Prompts nomeados
  SalvarPrompt(chat_id: String, nome: String, texto: String)
  ExcluirPrompt(chat_id: String, nome: String)
  AtivarPrompt(chat_id: String, nome: String)
  ListarPrompts(chat_id: String)
  // Métricas
  ConsultarMetricas(chat_id: String)
  ListarUsuarios(chat_id: String)
  ListarGrupos(chat_id: String)
  // Manutenção
  SnapshotHistorico(chat_id: String)
  NaoResponder
}

pub type TipoMidia {
  MidiaImagem
  MidiaAudio
  MidiaVideo
  MidiaDocumento
}
