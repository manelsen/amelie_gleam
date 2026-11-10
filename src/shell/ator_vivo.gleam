// Envio a um ator nomeado sem risco de panic.
//
// `process.send` a um nome sem dono (ator reiniciando) gera panic. Conferir
// com `process.named` antes e depois enviar pelo nome ainda deixa uma janela:
// o ator pode morrer entre as duas chamadas. Aqui o nome é resolvido uma vez
// e a mensagem vai ao processo encontrado; enviar a um processo morto não
// falha, a mensagem só se perde.

import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Subject}
import gleam/option.{type Option, None, Some}

/// O destino para envio seguro: o próprio subject, se não for nomeado, ou um
/// subject ligado ao processo que tem o nome agora. None se ninguém tem.
pub fn resolver(subject: Subject(a)) -> Option(Subject(a)) {
  case process.subject_name(subject) {
    Error(Nil) -> Some(subject)
    Ok(nome) ->
      case process.named(nome) {
        // Mesmo formato que process.send usa para um nome: {Nome, Msg}.
        Ok(pid) ->
          Some(process.unsafely_create_subject(pid, nome_para_dynamic(nome)))
        Error(Nil) -> None
      }
  }
}

/// Envia se houver quem receba. Devolve False se o ator não existir agora.
pub fn enviar(subject: Subject(a), mensagem: a) -> Bool {
  case resolver(subject) {
    Some(destino) -> {
      process.send(destino, mensagem)
      True
    }
    None -> False
  }
}

@external(erlang, "gleam_erlang_ffi", "identity")
fn nome_para_dynamic(nome: process.Name(a)) -> Dynamic
