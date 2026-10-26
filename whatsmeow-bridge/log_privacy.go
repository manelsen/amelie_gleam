package main

import (
	"log"
	"os"
	"strings"
)

// logPairingCode registra que um código de pareamento foi gerado. O código
// em si só vai ao log com PAIRING_CODE_IN_LOG=1.
func logPairingCode(phone, code string) {
	if !pairingCodeInLog() {
		log.Printf("[WhatsApp] Código de pareamento gerado para %s e enviado ao admin pelo Telegram. Para exibi-lo no log, defina PAIRING_CODE_IN_LOG=1.", maskID(phone))
		return
	}
	log.Println("==================================================")
	log.Printf("📱 PAIRING CODE GERADO PARA %s: %s\n", maskID(phone), code)
	log.Println("👉 No WhatsApp do celular:")
	log.Println("   Aparelhos conectados > Conectar com número de telefone")
	log.Printf("   e digite o código: %s\n", code)
	log.Println("==================================================")
}

// maskID mascara o identificador de um usuário para log: telefone, JID do
// WhatsApp (com ou sem agente/dispositivo) ou ID de grupo. Mantém os 4
// primeiros e os 4 últimos caracteres do usuário e o servidor, para que dê
// para correlacionar linhas de log sem expor o número inteiro.
func maskID(id string) string {
	local, server, hasServer := strings.Cut(id, "@")
	user, rest := local, ""
	if i := strings.IndexAny(local, ".:"); i >= 0 {
		user, rest = local[:i], local[i:]
	}
	masked := "****"
	if len(user) > 8 {
		masked = user[:4] + "****" + user[len(user)-4:]
	}
	if hasServer {
		return masked + rest + "@" + server
	}
	return masked + rest
}

// pairingCodeInLog diz se o código de pareamento pode aparecer no log.
// Por padrão não aparece: ele já chega ao admin pelo Telegram, e quem lê os
// logs do container poderia vincular um aparelho à conta enquanto ele vale.
// Instalações sem Telegram definem PAIRING_CODE_IN_LOG=1 para parear.
func pairingCodeInLog() bool {
	switch strings.ToLower(strings.TrimSpace(os.Getenv("PAIRING_CODE_IN_LOG"))) {
	case "1", "true", "sim", "yes":
		return true
	default:
		return false
	}
}
