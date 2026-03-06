pub type Erro {
  // Comunicação
  ErroComunicacao(descricao: String)
  ErroTimeout(operacao: String)
  ErroWhatsapp(descricao: String)

  // IA
  ErroIA(descricao: String)
  ErroIAIndisponivel
  ErroCircuitoAberto

  // Banco
  ErroBancoDados(descricao: String)

  // Domínio
  ErroValidacao(campo: String, motivo: String)
  ErroComandoDesconhecido(nome: String)
  ErroNaoAutorizado

  // Mídia
  ErroMidia(descricao: String)
  ErroUpload(descricao: String)
  ErroProcessamentoVideo(descricao: String)
}

pub fn descricao(erro: Erro) -> String {
  case erro {
    ErroComunicacao(d) -> "Comunicação: " <> d
    ErroTimeout(op) -> "Timeout em: " <> op
    ErroWhatsapp(d) -> "WhatsApp: " <> d
    ErroIA(d) -> "IA: " <> d
    ErroIAIndisponivel -> "IA indisponível"
    ErroCircuitoAberto -> "Circuito aberto — muitas falhas consecutivas"
    ErroBancoDados(d) -> "Banco: " <> d
    ErroValidacao(campo, motivo) -> "Validação [" <> campo <> "]: " <> motivo
    ErroComandoDesconhecido(nome) -> "Comando desconhecido: ." <> nome
    ErroNaoAutorizado -> "Não autorizado"
    ErroMidia(d) -> "Mídia: " <> d
    ErroUpload(d) -> "Upload: " <> d
    ErroProcessamentoVideo(d) -> "Vídeo: " <> d
  }
}
