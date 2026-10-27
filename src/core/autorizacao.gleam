// Autorização de ações administrativas. Puro — não faz IO.
//
// Uma regra só, usada pelo shell antes de executar qualquer Acao. Antes, a
// mesma checagem estava copiada em vários pontos de tratador_mensagem, e uma
// das cópias divergia (OU em vez de E).

import dominio/acao.{
  type Acao, AlterarModelo, AtivarPrompt, ConsultarMetricas, ConsultarSpammers,
  ConsultarStatus, DesbloquearChat, ExcluirPrompt, ListarGrupos, ListarPrompts,
  ListarUsuarios, ResetarWhatsApp, SalvarPrompt, SolicitarPareamento,
}
import dominio/id_chat.{type IdChat}
import dominio/mensagem.{type Mensagem}
import gleam/option.{type Option, Some}

/// Mensagem do administrador: conversa privada no Telegram cujo chat e
/// remetente são ambos o ID configurado. Sem ID configurado, ninguém é admin.
pub fn eh_admin(admin: Option(IdChat), msg: Mensagem) -> Bool {
  !msg.em_grupo && admin == Some(msg.remetente) && admin == Some(msg.chat_id)
}

/// Ações que só o administrador executa. Trocar de modelo entra aqui porque
/// a lista de modelos inclui opções dezenas de vezes mais caras que o padrão,
/// pagas pelo dono do bot.
pub fn exige_admin(acao: Acao) -> Bool {
  case acao {
    AlterarModelo(..)
    | SolicitarPareamento(..)
    | ConsultarStatus(..)
    | ResetarWhatsApp(..)
    | DesbloquearChat(..)
    | ConsultarSpammers(..)
    | ConsultarMetricas(..)
    | ListarUsuarios(..)
    | ListarGrupos(..)
    | SalvarPrompt(..)
    | ExcluirPrompt(..)
    | AtivarPrompt(..)
    | ListarPrompts(..) -> True
    _ -> False
  }
}

/// Decide se a ação pode ser executada para esta mensagem.
pub fn permitido(acao: Acao, admin: Option(IdChat), msg: Mensagem) -> Bool {
  !exige_admin(acao) || eh_admin(admin, msg)
}
