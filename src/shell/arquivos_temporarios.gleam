/// Cria mídia privada com nome aleatório, criação exclusiva e limite de 50 MiB.
@external(erlang, "amelie_gleam_ffi", "write_private_media")
pub fn gravar(dados: BitArray) -> Result(String, String)

/// Remove mídias temporárias órfãs com tempo de modificação superior a max_age_segundos.
@external(erlang, "amelie_gleam_ffi", "limpar_midias_antigas")
pub fn limpar_antigos(max_age_segundos: Int) -> Result(Int, String)

/// Apaga arquivo de mídia específico do disco.
@external(erlang, "amelie_gleam_ffi", "delete_file")
pub fn deletar(caminho: String) -> Result(Nil, String)
