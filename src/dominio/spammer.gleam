// dominio/spammer.gleam
// Tipos de domínio para auditoria e histórico de incidentes de anti-spam.

pub type IncidenteSpam {
  IncidenteSpam(
    id: Int,
    chat_id: String,
    remetente: String,
    telefone: String,
    motivo: String,
    strike: Int,
    criado_em: Int,
  )
}

pub type ResumoSpammer {
  ResumoSpammer(
    telefone: String,
    total_incidentes: Int,
    ultimo_strike: Int,
    ultimo_incidente_em: Int,
  )
}
