// O core não executa efeitos — prescreve Acoes.
// O shell as executa.

import dominio/config.{type Config}
import dominio/id_chat.{type IdChat}

pub type Acao {
  GerarEEnviar(para: IdChat, prompt: String)
  // Busca conteúdo da URL e injeta no prompt antes de chamar a IA.
  BuscarUrlEResponder(para: IdChat, texto: String, url: String)
  EnviarResposta(para: IdChat, corpo: String)
  EnfileirarMidia(chat_id: IdChat, tipo: TipoMidia)
  SalvarConfig(config: Config)
  LimparHistorico(chat_id: IdChat)
  // Prompts nomeados
  SalvarPrompt(chat_id: IdChat, nome: String, texto: String)
  ExcluirPrompt(chat_id: IdChat, nome: String)
  AtivarPrompt(chat_id: IdChat, nome: String)
  ListarPrompts(chat_id: IdChat)
  // Métricas
  ConsultarMetricas(chat_id: IdChat)
  ListarUsuarios(chat_id: IdChat)
  ListarGrupos(chat_id: IdChat)
  // Modelo/provedor
  AlterarModelo(chat_id: IdChat, provedor: String, modelo: String)
  // Manutenção
  SnapshotHistorico(chat_id: IdChat)
  // Administração / WhatsApp bridge
  SolicitarPareamento(chat_id: IdChat, args: String)
  ConsultarStatus(chat_id: IdChat)
  ResetarWhatsApp(chat_id: IdChat, args: String)
  DesbloquearChat(chat_id: IdChat, alvo: String)
  ConsultarSpammers(chat_id: IdChat)
  NaoResponder
}

pub type TipoMidia {
  MidiaImagem
  MidiaAudio
  MidiaVideo
  MidiaDocumento
  MidiaSticker
}
