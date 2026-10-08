// Utilitários de acessibilidade e sanitização para leitores de tela / voz artificial.
// Puro — sem efeitos.

import gleam/list
import gleam/string

/// Limpa decorações excessivas e formatações ruidosas para sintetizadores de tela
/// (TalkBack, NVDA, VoiceOver e JAWS).
pub fn sanitizar_saida_voz(texto: String) -> String {
  texto
  |> normalizar_linhas_decorativas
  |> suavizar_tabelas_markdown
  |> colapsar_repeticoes_decorativas
  |> colapsar_emojis_repetidos
  |> string.trim
}

/// Remove linhas inteiras formadas apenas por caracteres repetidos (ex: "---", "===", "***")
fn normalizar_linhas_decorativas(texto: String) -> String {
  texto
  |> string.split("\n")
  |> list.filter(fn(linha) {
    let t = string.trim(linha)
    case t {
      "---" | "----" | "-----" | "------" | "-------" | "--------" -> False
      "===" | "====" | "=====" | "======" | "=======" | "========" -> False
      "***" | "****" | "*****" | "******" | "*******" | "********" -> False
      "___" | "____" | "_____" | "______" | "_______" | "________" -> False
      "~~~" | "~~~~" | "~~~~~" | "~~~~~~" | "~~~~~~~" | "~~~~~~~~" -> False
      _ -> True
    }
  })
  |> string.join("\n")
}

/// Suaviza linhas de separador de tabela Markdown (ex: "|---|---|")
fn suavizar_tabelas_markdown(texto: String) -> String {
  texto
  |> string.split("\n")
  |> list.filter(fn(linha) {
    let t = string.trim(linha)
    // Descarta linhas separadoras de tabela Markdown que só contêm |, -, : e espaços
    let eh_separador_tabela =
      string.contains(t, "|")
      && string.contains(t, "-")
      && string.replace(t, "|", "")
      |> string.replace("-", "")
      |> string.replace(":", "")
      |> string.trim
      == ""
    !eh_separador_tabela
  })
  |> list.map(fn(linha) {
    // Se a linha começa e termina com |, remove as barras das pontas para leitura mais limpa
    let t = string.trim(linha)
    case string.starts_with(t, "|") && string.ends_with(t, "|") {
      True -> {
        t
        |> string.drop_start(1)
        |> string.drop_end(1)
        |> string.split("|")
        |> list.map(string.trim)
        |> string.join(" — ")
      }
      False -> linha
    }
  })
  |> string.join("\n")
}

/// Colapsa sequências no meio do texto com 4 ou mais caracteres repetidos decorativos
fn colapsar_repeticoes_decorativas(texto: String) -> String {
  texto
  |> string.replace("------", "--")
  |> string.replace("-----", "--")
  |> string.replace("----", "--")
  |> string.replace("====", "==")
  |> string.replace("===", "==")
  |> string.replace("******", "")
  |> string.replace("*****", "")
  |> string.replace("****", "")
  |> string.replace("~~~~", "~")
  |> string.replace("~~~", "~")
}

/// Colapsa repetições de emojis idênticos sucessivos (máximo 2)
fn colapsar_emojis_repetidos(texto: String) -> String {
  texto
  |> colapsar_padrao_repetido("❤️")
  |> colapsar_padrao_repetido("👍")
  |> colapsar_padrao_repetido("👏")
  |> colapsar_padrao_repetido("🔥")
  |> colapsar_padrao_repetido("✨")
  |> colapsar_padrao_repetido("⭐")
  |> colapsar_padrao_repetido("😂")
  |> colapsar_padrao_repetido("🎉")
}

fn colapsar_padrao_repetido(texto: String, padrao: String) -> String {
  let rep3 = padrao <> padrao <> padrao
  let rep2 = padrao <> padrao
  case string.contains(texto, rep3) {
    True -> {
      let reduzido = string.replace(texto, rep3, rep2)
      colapsar_padrao_repetido(reduzido, padrao)
    }
    False -> texto
  }
}
