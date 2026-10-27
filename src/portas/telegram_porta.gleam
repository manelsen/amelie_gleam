// Porta para a Bot API do Telegram além do envio de mensagens: receber
// updates por long polling, sinalizar atividade no chat e baixar arquivos.

import dominio/erro.{type Erro}
import dominio/mensagem.{type Mensagem}
import gleam/option.{type Option}

/// Indicador que o Telegram mostra no chat enquanto a Amélie trabalha.
pub type AcaoChat {
  Digitando
  EnviandoFoto
  EnviandoAudio
  EnviandoVideo
  EnviandoDocumento
  EscolhendoFigurinha
}

/// Um update do Telegram já classificado: mensagem pronta, mídia que ainda
/// precisa ser baixada via getFile, arquivo acima do limite ou ignorado.
pub type EventoUpdate {
  EventoMensagemPronta(update_id: Int, msg: Mensagem)
  EventoFotoParaBaixar(update_id: Int, base: Mensagem, file_id: String)
  EventoAudioParaBaixar(
    update_id: Int,
    base: Mensagem,
    file_id: String,
    mime: String,
  )
  EventoVideoParaBaixar(
    update_id: Int,
    base: Mensagem,
    file_id: String,
    mime: String,
  )
  EventoDocumentoParaBaixar(
    update_id: Int,
    base: Mensagem,
    file_id: String,
    mime: String,
    file_name: String,
  )
  EventoStickerParaBaixar(
    update_id: Int,
    base: Mensagem,
    file_id: String,
    mime: String,
  )
  EventoArquivoMuitoGrande(update_id: Int, chat_id: String, tamanho_mb: Int)
  EventoIgnorado(update_id: Int)
}

pub fn obter_update_id(evento: EventoUpdate) -> Int {
  case evento {
    EventoMensagemPronta(id, _) -> id
    EventoFotoParaBaixar(id, _, _) -> id
    EventoAudioParaBaixar(id, _, _, _) -> id
    EventoVideoParaBaixar(id, _, _, _) -> id
    EventoDocumentoParaBaixar(id, _, _, _, _) -> id
    EventoStickerParaBaixar(id, _, _, _) -> id
    EventoArquivoMuitoGrande(id, _, _) -> id
    EventoIgnorado(id) -> id
  }
}

pub type RespostaPolling {
  /// Updates do getUpdates, já decodificados.
  NovosUpdates(eventos: List(EventoUpdate))
  /// Há um webhook configurado; o polling deve parar.
  WebhookAtivo
  /// Outra instância está fazendo polling com o mesmo token.
  OutraInstancia
  /// Falha passageira: espera e tenta de novo. `aviso` vai para o log.
  FalhaPolling(aviso: Option(String), esperar_ms: Int)
}

pub type TelegramPorta {
  TelegramPorta(
    // obter_updates(offset)
    obter_updates: fn(Int) -> RespostaPolling,
    // sinalizar(chat_id, acao)
    sinalizar: fn(String, AcaoChat) -> Result(Nil, Erro),
    // baixar_arquivo(file_id)
    baixar_arquivo: fn(String) -> Result(BitArray, Erro),
  )
}
