import dominio/acao.{
  MidiaAudio, MidiaDocumento, MidiaImagem, MidiaSticker, MidiaVideo,
}
import dominio/transacao.{DescricaoMidia, RespostaIA, RespostaTexto}
import gleeunit/should
import helpers/fixtures

// Os textos ficam gravados na coluna `tipo` das transações já existentes;
// mudar algum deles separa o histórico antigo do novo.
pub fn tipo_entrega_mantem_os_textos_gravados_no_banco_test() {
  transacao.tipo_entrega_para_string(RespostaTexto) |> should.equal("texto")
  transacao.tipo_entrega_para_string(RespostaIA) |> should.equal("ia_texto")
  transacao.tipo_entrega_para_string(DescricaoMidia(MidiaImagem))
  |> should.equal("imagem")
  transacao.tipo_entrega_para_string(DescricaoMidia(MidiaAudio))
  |> should.equal("audio")
  transacao.tipo_entrega_para_string(DescricaoMidia(MidiaVideo))
  |> should.equal("video")
  transacao.tipo_entrega_para_string(DescricaoMidia(MidiaDocumento))
  |> should.equal("documento")
  transacao.tipo_entrega_para_string(DescricaoMidia(MidiaSticker))
  |> should.equal("sticker")
}

pub fn transacao_nova_sai_em_nome_do_bot_test() {
  let tx = transacao.novo(fixtures.id("chat1@c.us"), RespostaIA, "oi")
  tx.remetente |> should.equal("amelie")
  tx.tipo |> should.equal("ia_texto")
}
