// Busca e extrai texto de URLs para injeção no contexto da IA.
// Remove scripts, estilos, navegação e ruídos para entregar um texto limpo
// e acessível para a IA resumir.

import adaptadores/whatsmeow_http
import dominio/erro.{type Erro}
import gleam/list
import gleam/result
import gleam/string

pub const max_chars = 6000

pub fn buscar(url: String) -> Result(String, Erro) {
  let bridge_url =
    get_env("WHATSMEOW_URL") |> result.unwrap("http://localhost:8080")
  use html <- result.try(whatsmeow_http.buscar_pagina(bridge_url, url))
  html |> extrair_texto |> truncar(max_chars) |> Ok
}

@external(erlang, "amelie_gleam_ffi", "get_env")
fn get_env(name: String) -> Result(String, Nil)

/// Extrai o conteúdo textual de uma página HTML, descartando ruídos como
/// scripts, estilos, tags de cabeçalho/rodapé e menus.
pub fn extrair_texto(html: String) -> String {
  html
  |> remover_blocos_inuteis
  |> selecionar_conteudo_principal
  |> converter_quebras
  |> strip_tags
  |> decodificar_entidades
  |> colapsar_espacos
  |> string.trim
}

fn remover_blocos_inuteis(html: String) -> String {
  html
  |> remover_bloco("<script", "</script>")
  |> remover_bloco("<style", "</style>")
  |> remover_bloco("<head>", "</head>")
  |> remover_bloco("<head ", "</head>")
  |> remover_bloco("<nav", "</nav>")
  |> remover_bloco("<header", "</header>")
  |> remover_bloco("<footer", "</footer>")
  |> remover_bloco("<aside", "</aside>")
  |> remover_bloco("<svg", "</svg>")
  |> remover_bloco("<noscript", "</noscript>")
  |> remover_bloco("<iframe", "</iframe>")
}

fn selecionar_conteudo_principal(html: String) -> String {
  case extrair_miolo_bloco(html, "<article", "</article>") {
    Ok(conteudo) ->
      case string.length(conteudo) > 50 {
        True -> conteudo
        False -> extrair_fallback(html)
      }
    _ -> extrair_fallback(html)
  }
}

fn extrair_fallback(html: String) -> String {
  case extrair_miolo_bloco(html, "<main", "</main>") {
    Ok(conteudo) ->
      case string.length(conteudo) > 50 {
        True -> conteudo
        False -> extrair_body_ou_html(html)
      }
    _ -> extrair_body_ou_html(html)
  }
}

fn extrair_body_ou_html(html: String) -> String {
  case extrair_miolo_bloco(html, "<body", "</body>") {
    Ok(conteudo) -> conteudo
    _ -> html
  }
}

fn extrair_miolo_bloco(
  html: String,
  abertura: String,
  fechamento: String,
) -> Result(String, Nil) {
  let lower = string.lowercase(html)
  use #(antes_lower, _) <- result.try(string.split_once(lower, abertura))
  let idx_abertura = string.length(antes_lower)
  let resto =
    string.slice(html, idx_abertura, string.length(html) - idx_abertura)

  // Encontra o fim da tag de abertura (o caractere '>')
  use #(_, resto_apos_tag) <- result.try(string.split_once(resto, ">"))
  let resto_apos_tag_lower = string.lowercase(resto_apos_tag)

  use #(miolo_lower, _) <- result.try(string.split_once(
    resto_apos_tag_lower,
    fechamento,
  ))
  let len_miolo = string.length(miolo_lower)
  Ok(string.slice(resto_apos_tag, 0, len_miolo))
}

fn remover_bloco(html: String, abertura: String, fechamento: String) -> String {
  let lower = string.lowercase(html)
  case string.split_once(lower, abertura) {
    Error(_) -> html
    Ok(#(antes_lower, _)) -> {
      let idx_abertura = string.length(antes_lower)
      let parte_antes = string.slice(html, 0, idx_abertura)
      let resto =
        string.slice(html, idx_abertura, string.length(html) - idx_abertura)
      let resto_lower = string.lowercase(resto)

      case string.split_once(resto_lower, fechamento) {
        Error(_) -> html
        Ok(#(miolo_lower, _)) -> {
          let idx_fim = string.length(miolo_lower) + string.length(fechamento)
          let parte_depois =
            string.slice(resto, idx_fim, string.length(resto) - idx_fim)
          remover_bloco(
            parte_antes <> " " <> parte_depois,
            abertura,
            fechamento,
          )
        }
      }
    }
  }
}

fn converter_quebras(html: String) -> String {
  html
  |> string.replace("<br>", "\n")
  |> string.replace("<br/>", "\n")
  |> string.replace("<br />", "\n")
  |> string.replace("</p>", "\n")
  |> string.replace("</div>", "\n")
  |> string.replace("</h1>", "\n")
  |> string.replace("</h2>", "\n")
  |> string.replace("</h3>", "\n")
  |> string.replace("</h4>", "\n")
  |> string.replace("</h5>", "\n")
  |> string.replace("</h6>", "\n")
  |> string.replace("</li>", "\n")
  |> string.replace("</tr>", "\n")
}

fn strip_tags(html: String) -> String {
  html
  |> string.split("<")
  |> list.index_map(fn(parte, i) {
    case i == 0 {
      True -> parte
      False ->
        case string.split_once(parte, ">") {
          Ok(#(_, apos)) -> " " <> apos
          Error(_) -> ""
        }
    }
  })
  |> string.join("")
}

fn decodificar_entidades(s: String) -> String {
  s
  |> string.replace("&nbsp;", " ")
  |> string.replace("&amp;", "&")
  |> string.replace("&quot;", "\"")
  |> string.replace("&#39;", "'")
  |> string.replace("&apos;", "'")
  |> string.replace("&lt;", "<")
  |> string.replace("&gt;", ">")
  |> string.replace("&ndash;", "-")
  |> string.replace("&#8211;", "-")
  |> string.replace("&mdash;", "—")
  |> string.replace("&#8212;", "—")
  |> string.replace("&ldquo;", "\"")
  |> string.replace("&#8220;", "\"")
  |> string.replace("&rdquo;", "\"")
  |> string.replace("&#8221;", "\"")
  |> string.replace("&lsquo;", "'")
  |> string.replace("&#8216;", "'")
  |> string.replace("&rsquo;", "'")
  |> string.replace("&#8217;", "'")
  |> string.replace("&hellip;", "...")
  |> string.replace("&#8230;", "...")
  |> string.replace("&copy;", "")
  |> string.replace("&reg;", "")
}

fn colapsar_espacos(s: String) -> String {
  s
  |> string.split("\n")
  |> list.map(string.trim)
  |> list.filter(fn(linha) { linha != "" })
  |> string.join("\n")
}

fn truncar(s: String, max: Int) -> String {
  case string.length(s) > max {
    True -> string.slice(s, 0, max) <> "…"
    False -> s
  }
}
