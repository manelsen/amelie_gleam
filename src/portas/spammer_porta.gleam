// portas/spammer_porta.gleam
// Interface abstrata para persistência de incidentes de anti-spam.

import dominio/erro.{type Erro}
import dominio/id_chat.{type IdChat}
import dominio/spammer.{type IncidenteSpam, type ResumoSpammer}

pub type SpammerPorta {
  SpammerPorta(
    registrar: fn(IdChat, IdChat, String, String, Int) -> Result(Nil, Erro),
    listar_recentes: fn(Int) -> Result(List(IncidenteSpam), Erro),
    listar_top: fn(Int) -> Result(List(ResumoSpammer), Erro),
    contar: fn() -> Result(Int, Erro),
  )
}
