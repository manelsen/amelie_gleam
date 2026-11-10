import dominio/texto_partes
import gleam/list
import gleam/string
import gleeunit/should

// ---------------------------------------------------------------------------
// dividir — limite de tamanho do canal
// ---------------------------------------------------------------------------

pub fn texto_curto_vai_inteiro_test() {
  texto_partes.dividir("oi", 10) |> should.equal(["oi"])
}

pub fn corta_entre_paragrafos_test() {
  texto_partes.dividir("aaaa bbbb\n\ncccc", 12)
  |> should.equal(["aaaa bbbb", "cccc"])
}

pub fn corta_entre_palavras_sem_quebra_de_linha_test() {
  texto_partes.dividir("aaaa bbbb cccc", 10)
  |> should.equal(["aaaa bbbb", "cccc"])
}

pub fn palavra_maior_que_o_limite_e_cortada_test() {
  texto_partes.dividir("abcdefghij", 4)
  |> should.equal(["abcd", "efgh", "ij"])
}

pub fn emoji_conta_como_duas_unidades_test() {
  // Cada 😀 ocupa 2 unidades UTF-16; 3 deles passam de 5.
  texto_partes.dividir("😀😀😀", 5)
  |> should.equal(["😀😀", "😀"])
}

pub fn texto_ascii_longo_nenhuma_parte_passa_do_limite_test() {
  let texto = string.repeat("palavra ", 1500)
  let partes = texto_partes.dividir(texto, texto_partes.limite_telegram)
  list.length(partes) |> should.equal(3)
  list.all(partes, fn(p) { string.length(p) <= texto_partes.limite_telegram })
  |> should.be_true
  string.join(partes, " ") |> string.trim |> should.equal(string.trim(texto))
}
