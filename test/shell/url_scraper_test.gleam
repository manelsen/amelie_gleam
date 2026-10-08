// Testes do extrator de conteúdo textual de páginas web (url_scraper).

import gleam/string
import gleeunit/should
import shell/url_scraper

pub fn extrai_texto_simples_test() {
  let html =
    "<html><body><h1>Título da Notícia</h1><p>Parágrafo informativo.</p></body></html>"
  let texto = url_scraper.extrair_texto(html)
  texto |> should.equal("Título da Notícia\nParágrafo informativo.")
}

pub fn descarta_scripts_e_estilos_completamente_test() {
  let html =
    "<html><head><script>alert('malware'); var x = 123;</script><style>body { color: red; }</style></head>"
    <> "<body><p>Conteúdo real que deve sobrar.</p><script>console.log('tracker');</script></body></html>"

  let texto = url_scraper.extrair_texto(html)
  texto |> should.equal("Conteúdo real que deve sobrar.")
  string.contains(texto, "alert") |> should.be_false
  string.contains(texto, "color: red") |> should.be_false
  string.contains(texto, "tracker") |> should.be_false
}

pub fn descarta_menus_e_rodapes_test() {
  let html =
    "<body>"
    <> "<header><nav><a href='/home'>Início</a> <a href='/contato'>Contato</a></nav></header>"
    <> "<article><p>O projeto Amélie avançou para a segunda fase de melhorias de acessibilidade com sucesso.</p></article>"
    <> "<aside>Anúncios e links patrocinados</aside>"
    <> "<footer>Todos os direitos reservados 2026</footer>"
    <> "</body>"

  let texto = url_scraper.extrair_texto(html)
  string.contains(texto, "O projeto Amélie avançou") |> should.be_true
  string.contains(texto, "Início") |> should.be_false
  string.contains(texto, "Contato") |> should.be_false
  string.contains(texto, "patrocinados") |> should.be_false
  string.contains(texto, "direitos reservados") |> should.be_false
}

pub fn decodifica_entidades_html_test() {
  let html =
    "<p>Preço &amp; valor: R$&nbsp;50,00 &mdash; &ldquo;oferta especial&rdquo; &#39;amigo&#39;</p>"
  let texto = url_scraper.extrair_texto(html)
  texto |> should.equal("Preço & valor: R$ 50,00 — \"oferta especial\" 'amigo'")
}
