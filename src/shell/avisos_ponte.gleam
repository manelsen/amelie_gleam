//// Avisos ao admin sobre o estado da conexão do WhatsApp (queda, volta e
//// código de pareamento), vindos da ponte.

import dominio/erro.{type Erro}
import dominio/id_chat.{type IdChat}
import gleam/option.{type Option, None, Some}
import portas/mensageiro_porta.{type MensageiroPorta}
import portas/ponte_porta.{
  type EventoPonte, CodigoPareamentoGerado, WhatsappCaiu, WhatsappVoltou,
}

/// Envia o aviso ao admin. Sem admin (ou sem Telegram, caso em que o `main`
/// passa `None`), o evento é aceito sem envio.
pub fn avisar(
  evento: EventoPonte,
  mensageiro: MensageiroPorta,
  admin: Option(IdChat),
) -> Result(Nil, Erro) {
  case admin {
    None -> Ok(Nil)
    Some(admin) -> mensageiro.enviar(admin, texto(evento))
  }
}

pub fn texto(evt: EventoPonte) -> String {
  case evt {
    CodigoPareamentoGerado(phone, code) ->
      "⚠️ *Alerta: WhatsApp desconectado!*\n\n"
      <> "📱 *Novo código de pareamento para* `+"
      <> phone
      <> "`:\n"
      <> "`"
      <> code
      <> "`\n\n"
      <> "👉 *No WhatsApp do seu celular:*\n"
      <> "Aparelhos conectados > Conectar com número de telefone > Digite o código acima.\n\n"
      <> "⏳ Vale por cerca de 2 minutos. Se expirar, mando outro, e os anteriores deixam de valer."
    WhatsappCaiu(motivo) ->
      "⚠️ *Alerta: A conexão do WhatsApp caiu!*\n\n"
      <> "Motivo: "
      <> motivo
      <> "\n\n"
      <> "Para gerar um novo código de pareamento, envie:\n"
      <> "`/parear <seu_numero>`"
    WhatsappVoltou ->
      "✅ *A Amélie voltou!*\n\n"
      <> "O WhatsApp está conectado e atendendo de novo."
  }
}
