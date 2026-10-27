package main

import "regexp"

// mimePattern aceita só tipo/subtipo com caracteres de token, sem parâmetros.
var mimePattern = regexp.MustCompile(`^[a-z0-9][a-z0-9.+-]*/[a-z0-9][a-z0-9.+-]*$`)

// sanitizeMime normaliza o MIME declarado pelo remetente antes de mandá-lo
// ao Gleam. O valor chegava cru e era concatenado no JSON e no cabeçalho do
// multipart de upload ao Gemini; aspas ou CRLF reescreviam o upload.
// Valor vazio continua vazio (mensagens de texto); inválido vira
// application/octet-stream.
func sanitizeMime(raw string) string {
	if raw == "" {
		return ""
	}
	mime := normalizeMime(raw)
	if mime == "" || len(mime) > 127 || !mimePattern.MatchString(mime) {
		return "application/octet-stream"
	}
	return mime
}
