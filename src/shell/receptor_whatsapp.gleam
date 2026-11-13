//// Recebe as mensagens do WhatsApp já decodificadas pela ponte e as entrega
//// ao tratador. É o par do `receptor_telegram` para o WhatsApp.

import core/privacidade
import dominio/mensagem.{type Mensagem, Mensagem}
import gleam/int
import gleam/option
import logging
import portas/ponte_porta.{type Webhook}
import shell/arquivos_temporarios
import shell/fila_atrasadas.{type FilaAtrasadas}
import shell/sistema
import shell/tratador/base.{type Portas}
import shell/tratador_mensagem

/// Processa em processo isolado — o webhook retorna imediatamente e não
/// bloqueia o Mist durante chamadas à IA (2-10s). Mensagens enviadas enquanto
/// a Amélie estava fora do ar vão para a fila serial, uma por vez.
pub fn despachar(
  webhook: Webhook,
  portas: Portas,
  atrasadas: FilaAtrasadas,
) -> Nil {
  case fila_atrasadas.e_atrasada(webhook.msg.timestamp, sistema.agora_s()) {
    False ->
      sistema.disparar(fn() {
        tratador_mensagem.tratar(carregar_midia(webhook), portas)
      })
    True -> {
      logging.log(
        logging.Info,
        "["
          <> base.extrair_trace_id(webhook.msg)
          <> "] Mensagem atrasada "
          <> int.to_string(sistema.agora_s() - webhook.msg.timestamp)
          <> "s, enviada à fila serial: "
          <> privacidade.mascarar(webhook.msg.chat_id),
      )
      // A mídia sai do spool já, e não quando chegar a vez na fila.
      let msg = carregar_midia(webhook)
      fila_atrasadas.enfileirar(atrasadas, fn() {
        let _ = tratador_mensagem.tratar_atrasada(msg, portas)
        Nil
      })
    }
  }
}

/// Lê do disco a mídia gravada pelo bridge e apaga o arquivo. Se a leitura
/// falhar, responde ao usuário em vez de processar mídia vazia.
fn carregar_midia(webhook: Webhook) -> Mensagem {
  case webhook.arquivo {
    option.None -> webhook.msg
    option.Some(caminho) -> {
      let corpo = case arquivos_temporarios.ler_da_ponte(caminho) {
        Ok(bytes) -> com_bytes(webhook.msg.corpo, bytes)
        Error(motivo) -> {
          logging.log(
            logging.Warning,
            "Falha ao ler mídia temporária "
              <> caminho
              <> " de "
              <> privacidade.mascarar(webhook.msg.chat_id)
              <> ": "
              <> motivo,
          )
          mensagem.MidiaIndisponivel(
            mensagem: "Não consegui ler a mídia que você enviou. Pode reenviar?",
          )
        }
      }
      Mensagem(..webhook.msg, corpo: corpo)
    }
  }
}

fn com_bytes(corpo: mensagem.Conteudo, bytes: BitArray) -> mensagem.Conteudo {
  case corpo {
    mensagem.Imagem(mime: mime, ..) -> mensagem.Imagem(mime: mime, dados: bytes)
    mensagem.Audio(mime: mime, ..) -> mensagem.Audio(mime: mime, dados: bytes)
    mensagem.Documento(mime: mime, nome: nome, ..) ->
      mensagem.Documento(mime: mime, dados: bytes, nome: nome)
    mensagem.Sticker(mime: mime, ..) ->
      mensagem.Sticker(mime: mime, dados: bytes)
    outro -> outro
  }
}
