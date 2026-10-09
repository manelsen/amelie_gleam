import gleam/bit_array
import gleeunit/should
import shell/arquivos_temporarios
import simplifile

pub fn gravar_e_deletar_arquivo_test() {
  let dados = bit_array.from_string("conteudo de teste para midia")
  let assert Ok(caminho) = arquivos_temporarios.gravar(dados)

  // Verifica que arquivo foi gravado no disco
  simplifile.is_file(caminho)
  |> should.equal(Ok(True))

  // Apaga o arquivo
  arquivos_temporarios.deletar(caminho)
  |> should.equal(Ok(Nil))

  // Verifica que não existe mais
  simplifile.is_file(caminho)
  |> should.equal(Ok(False))
}

pub fn limpar_antigos_preserva_arquivos_recentes_test() {
  let dados = bit_array.from_string("arquivo temporario recente")
  let assert Ok(caminho) = arquivos_temporarios.gravar(dados)

  // Varredura com 3600 segundos não deve remover o arquivo recém-criado
  let assert Ok(_) = arquivos_temporarios.limpar_antigos(3600)

  simplifile.is_file(caminho)
  |> should.equal(Ok(True))

  // Limpeza
  let _ = arquivos_temporarios.deletar(caminho)
  Nil
}

pub fn limpar_antigos_remove_arquivos_com_idade_zero_test() {
  let dados = bit_array.from_string("arquivo temporario para expirar")
  let assert Ok(caminho) = arquivos_temporarios.gravar(dados)

  // Com limite 0 segundos, qualquer arquivo existente é considerado elegível
  let resultado = arquivos_temporarios.limpar_antigos(0)
  let assert Ok(qtd) = resultado

  should.be_true(qtd >= 1)

  // Verifica que o arquivo específico foi removido
  simplifile.is_file(caminho)
  |> should.equal(Ok(False))
}
