// Divisão de texto longo em partes que cabem no limite de um canal. Puro.
// Usada pela entrega auditada (cada parte vira uma entrega própria) e pelo
// adaptador do Telegram (envios que não passam pela auditoria).

import gleam/int
import gleam/list
import gleam/string

/// Abaixo dos 4096 da Bot API: a margem cobre a contagem depois que o
/// Markdown é interpretado.
pub const limite_telegram = 4000

/// Divide o texto em partes de até `limite` unidades UTF-16 (a medida da Bot
/// API), cortando de preferência entre parágrafos, depois entre linhas e
/// depois entre palavras. Texto dentro do limite volta inteiro. O corte não
/// conhece o Markdown: se cair dentro de um `*negrito*`, o Telegram recusa a
/// formatação e aquela parte vai sem ela, pelo reenvio sem `parse_mode`.
pub fn dividir(texto: String, limite: Int) -> List(String) {
  case unidades_utf16(texto) <= limite {
    True -> [texto]
    False -> {
      let grafemas = string.to_graphemes(texto)
      let cabe = quantos_cabem(grafemas, limite, 0, 0)
      let corte = melhor_corte(list.take(grafemas, cabe), cabe)
      let parte = list.take(grafemas, corte) |> string.concat |> string.trim_end
      let resto =
        list.drop(grafemas, corte) |> string.concat |> string.trim_start
      case resto {
        "" -> [parte]
        _ -> [parte, ..dividir(resto, limite)]
      }
    }
  }
}

fn quantos_cabem(
  grafemas: List(String),
  limite: Int,
  usadas: Int,
  contagem: Int,
) -> Int {
  case grafemas {
    [] -> contagem
    [g, ..resto] -> {
      let total = usadas + unidades_utf16(g)
      case total > limite {
        True -> int.max(contagem, 1)
        False -> quantos_cabem(resto, limite, total, contagem + 1)
      }
    }
  }
}

/// Posição de corte dentro dos grafemas que cabem. Um separador na primeira
/// metade geraria partes curtas demais; nesse caso corta no limite.
fn melhor_corte(cabem: List(String), total: Int) -> Int {
  let minimo = total / 2
  let ultimo = fn(pred: fn(String, String) -> Bool) {
    ultimo_indice(cabem, "", 0, -1, pred)
  }
  let paragrafo = ultimo(fn(ant, g) { e_quebra(ant) && e_quebra(g) })
  let linha = ultimo(fn(_, g) { e_quebra(g) })
  let espaco = ultimo(fn(_, g) { g == " " })
  case paragrafo > minimo, linha > minimo, espaco > minimo {
    True, _, _ -> paragrafo + 1
    _, True, _ -> linha + 1
    _, _, True -> espaco + 1
    _, _, _ -> total
  }
}

fn ultimo_indice(
  grafemas: List(String),
  anterior: String,
  i: Int,
  achado: Int,
  pred: fn(String, String) -> Bool,
) -> Int {
  case grafemas {
    [] -> achado
    [g, ..resto] -> {
      let achado = case pred(anterior, g) {
        True -> i
        False -> achado
      }
      ultimo_indice(resto, g, i + 1, achado, pred)
    }
  }
}

fn e_quebra(g: String) -> Bool {
  g == "\n" || g == "\r\n"
}

fn unidades_utf16(texto: String) -> Int {
  string.to_utf_codepoints(texto)
  |> list.fold(0, fn(soma, cp) {
    case string.utf_codepoint_to_int(cp) > 0xFFFF {
      True -> soma + 2
      False -> soma + 1
    }
  })
}
