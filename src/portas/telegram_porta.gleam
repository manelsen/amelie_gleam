// Porta para a Bot API do Telegram além do envio de mensagens: receber
// updates por long polling, sinalizar atividade no chat e baixar arquivos.

import dominio/erro.{type Erro}
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

pub type RespostaPolling {
  /// Corpo JSON do getUpdates, ainda por decodificar.
  NovosUpdates(corpo: String)
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
