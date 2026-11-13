// Base comum dos módulos do tratador: as portas e as formas de responder.

import core/acessibilidade
import core/privacidade
import dominio/erro.{type Erro}
import dominio/id_chat.{type IdChat}
import dominio/mensagem.{type Mensagem, Audio, Documento, Imagem, Texto, Video}
import dominio/provedores_config.{type ProvedoresConfig}
import dominio/transacao.{type TipoEntrega, RespostaTexto}
import gleam/int
import gleam/option
import gleam/string
import portas/config_porta.{type ConfigPorta}
import portas/grupo_porta.{type GrupoPorta}
import portas/historico_porta.{type HistoricoPorta}
import portas/mensageiro_porta.{type MensageiroPorta}
import portas/ponte_porta.{type PontePorta}
import portas/prompt_porta.{type PromptPorta}
import portas/spammer_porta.{type SpammerPorta}
import portas/transacao_porta.{type TransacaoPorta}
import portas/usuario_porta.{type UsuarioPorta}
import portas/video_contexto_porta.{type VideoContextoPorta}
import shell/anti_spam.{type AntiSpam}
import shell/despachante_ia
import shell/entrega_auditada
import shell/fila_midia.{type FilasMidia}
import shell/metricas.{type Metricas}
import shell/sistema

pub type Portas {
  Portas(
    mensageiro: MensageiroPorta,
    despachante_ia: despachante_ia.DespachanteIA,
    config: ConfigPorta,
    historico: HistoricoPorta,
    fila: FilasMidia,
    prompts: PromptPorta,
    metricas: Metricas,
    usuarios: UsuarioPorta,
    grupos: GrupoPorta,
    transacoes: TransacaoPorta,
    provedores_config: ProvedoresConfig,
    anti_spam: AntiSpam,
    spammers: SpammerPorta,
    video_contexto: VideoContextoPorta,
    ponte: PontePorta,
  )
}

pub fn extrair_trace_id(msg: Mensagem) -> String {
  let id = case msg.message_id {
    option.Some(id) if id != "" -> id
    _ ->
      "req_"
      <> int.to_string(msg.timestamp)
      <> "_"
      <> id_chat.para_texto(msg.remetente)
  }
  string.slice(id, 0, 5)
}

// Envia citando a mensagem original quando possível; cai em envio simples caso contrário.
pub fn entregar(
  para: IdChat,
  tipo: TipoEntrega,
  conteudo: String,
  msg: Mensagem,
  portas: Portas,
) -> Result(Nil, Erro) {
  let conteudo_sanitizado = acessibilidade.sanitizar_saida_voz(conteudo)
  case msg.message_id {
    option.Some(mid) ->
      entrega_auditada.enviar_citando(
        para,
        tipo,
        conteudo_sanitizado,
        mid,
        msg.remetente,
        portas.mensageiro,
        portas.transacoes,
      )
    option.None ->
      entrega_auditada.enviar(
        para,
        tipo,
        conteudo_sanitizado,
        portas.mensageiro,
        portas.transacoes,
      )
  }
}

/// Resposta de texto auditada, sem citar a mensagem original.
pub fn responder(
  para: IdChat,
  texto: String,
  portas: Portas,
) -> Result(Nil, Erro) {
  entrega_auditada.enviar(
    para,
    RespostaTexto,
    texto,
    portas.mensageiro,
    portas.transacoes,
  )
}

/// Aviso direto pelo mensageiro, sem auditoria: recusas, avisos de limite e
/// respostas administrativas. Uma falha de envio vai para o log e não vira
/// erro da mensagem, porque o usuário não teria como receber o aviso de erro.
pub fn avisar(para: IdChat, texto: String, portas: Portas) -> Result(Nil, Erro) {
  portas.mensageiro.enviar(para, texto)
  |> sistema.registrar_falha(
    "Falha ao enviar aviso para " <> privacidade.mascarar(para),
  )
  Ok(Nil)
}

pub fn extrair_texto_usuario(msg: Mensagem) -> String {
  case msg.corpo {
    Texto(body) -> body
    Imagem(..) -> "[imagem]"
    Audio(..) -> "[áudio]"
    Video(..) -> "[vídeo]"
    Documento(nome: nome, ..) -> "[documento: " <> nome <> "]"
    mensagem.Sticker(..) -> "[sticker]"
    mensagem.MidiaIndisponivel(..) -> "[mídia indisponível]"
    mensagem.Comando(nome, args) -> "." <> nome <> " " <> args
  }
}
