// Testes de sanitização de texto para sintetizadores de tela.

import core/acessibilidade
import gleam/string
import gleeunit/should

pub fn remove_linhas_decorativas_repetidas_test() {
  let entrada =
    "Resumo da notícia:\n---\nConteúdo importante aqui.\n========\nMais detalhes."
  let saida = acessibilidade.sanitizar_saida_voz(entrada)
  saida
  |> should.equal(
    "Resumo da notícia:\nConteúdo importante aqui.\nMais detalhes.",
  )
}

pub fn suaviza_tabelas_markdown_test() {
  let entrada =
    "Itens:\n| Produto | Preço |\n|---|---|\n| Arroz | R$ 10 |\n| Feijão | R$ 8 |"
  let saida = acessibilidade.sanitizar_saida_voz(entrada)
  string.contains(saida, "|---|---|") |> should.be_false
  string.contains(saida, "Arroz — R$ 10") |> should.be_true
  string.contains(saida, "Feijão — R$ 8") |> should.be_true
}

pub fn colapsa_emojis_excessivos_test() {
  let entrada = "Parabéns pelo trabalho! 🎉🎉🎉🎉🎉 Muito bom! 👍👍👍👍"
  let saida = acessibilidade.sanitizar_saida_voz(entrada)
  saida |> should.equal("Parabéns pelo trabalho! 🎉🎉 Muito bom! 👍👍")
}

pub fn mantem_texto_normal_intacto_test() {
  let normal =
    "Olá! Este é um texto comum, bem pontuado e formatado para leitura."
  let saida = acessibilidade.sanitizar_saida_voz(normal)
  saida |> should.equal(normal)
}
