// Regras de URL para a API do Gemini. Puro — não faz IO.

import gleam/string

/// Prefixo de toda URL legítima da API do Gemini.
pub const prefixo_api = "https://generativelanguage.googleapis.com/"

/// Diz se a URL aponta para a API do Gemini, por HTTPS. A chave de API só
/// pode ser anexada a requisições que passem nesta checagem.
pub fn url_da_api(url: String) -> Bool {
  string.starts_with(url, prefixo_api)
}
