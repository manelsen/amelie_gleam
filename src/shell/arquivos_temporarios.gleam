/// Cria mídia privada com nome aleatório, criação exclusiva e limite de 50 MiB.
@external(erlang, "amelie_gleam_ffi", "write_private_media")
pub fn gravar(dados: BitArray) -> Result(String, String)
