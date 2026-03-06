import dominio/erro.{type Erro}
import dominio/mensagem.{type Turno}

pub type IAPorta {
  IAPorta(
    gerar_texto: fn(String, List(Turno), String) -> Result(String, Erro),
    processar_imagem: fn(BitArray, String, String, String) -> Result(String, Erro),
    processar_audio: fn(BitArray, String, String) -> Result(String, Erro),
    processar_video: fn(String, String, String) -> Result(String, Erro),
    processar_documento: fn(BitArray, String, String, String) -> Result(String, Erro),
    // caminho_temp, mime -> uri google
    fazer_upload_video: fn(String, String) -> Result(String, Erro),
    aguardar_video_ativo: fn(String) -> Result(Nil, Erro),
    deletar_arquivo: fn(String) -> Result(Nil, Erro),
  )
}
