// Provedores de IA com adaptador implementado.
// O nome em texto aparece na configuração (providers.yaml), no SQLite e no
// comando `.modelo`; dentro do código circula só o tipo.

pub type Provedor {
  Gemini
  OpenRouter
}

pub fn para_string(provedor: Provedor) -> String {
  case provedor {
    Gemini -> "gemini"
    OpenRouter -> "openrouter"
  }
}

pub fn de_string(nome: String) -> Result(Provedor, Nil) {
  case nome {
    "gemini" -> Ok(Gemini)
    "openrouter" -> Ok(OpenRouter)
    _ -> Error(Nil)
  }
}
