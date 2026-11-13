package main

import (
	"os"
	"strings"
)

type Config struct {
	Port     string // Porta HTTP deste bridge (default: 8080)
	Host     string // Interface privada (default: 127.0.0.1)
	Token    string // Segredo compartilhado com o Gleam
	GleamURL string // URL do webhook Gleam (default: http://localhost:4000/webhook)
	DBPath   string // SQLite para sessão WhatsApp (default: ./db/whatsmeow.db)
	BotPhone string // Número para Pairing Code (opcional, ativa Pairing Code se definido)
}

func configFromEnv() Config {
	return Config{
		Port:     getEnv("BRIDGE_PORT", "8080"),
		Host:     getEnv("BRIDGE_HOST", "127.0.0.1"),
		Token:    getEnv("BRIDGE_TOKEN", ""),
		GleamURL: getEnv("GLEAM_URL", "http://localhost:4000/webhook"),
		DBPath:   getEnv("BRIDGE_DB_PATH", "./db/whatsmeow.db"),
		BotPhone: getEnv("MOBILE_NUMBER", ""),
	}
}

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// cleanPhoneNumber sanitiza o número de telefone para o formato internacional exigido pelo WhatsApp.
// Remove caracteres não-numéricos, zeros à esquerda, adiciona DDI 55 para números brasileiros de 10/11 dígitos
// e normaliza celulares brasileiros inserindo o 9º dígito quando ausente.
func cleanPhoneNumber(phone string) string {
	var sb strings.Builder
	for _, r := range phone {
		if r >= '0' && r <= '9' {
			sb.WriteRune(r)
		}
	}
	cleaned := strings.TrimLeft(sb.String(), "0")
	if !strings.HasPrefix(cleaned, "55") && (len(cleaned) == 10 || len(cleaned) == 11) {
		ddd := 0
		if len(cleaned) >= 2 {
			ddd = int(cleaned[0]-'0')*10 + int(cleaned[1]-'0')
		}
		if ddd >= 11 && ddd <= 99 {
			cleaned = "55" + cleaned
		}
	}

	// Normaliza celulares brasileiros: se tem DDI 55 + DDD válido (11-99) + 8 dígitos locais iniciados em 6, 7, 8 ou 9,
	// insere o 9º dígito ('9') após o DDD, totalizando 13 dígitos.
	if strings.HasPrefix(cleaned, "55") && len(cleaned) == 12 {
		ddd := int(cleaned[2]-'0')*10 + int(cleaned[3]-'0')
		if ddd >= 11 && ddd <= 99 {
			firstLocalDigit := cleaned[4]
			if firstLocalDigit >= '6' && firstLocalDigit <= '9' {
				cleaned = "55" + cleaned[2:4] + "9" + cleaned[4:]
			}
		}
	}

	return cleaned
}

// samePhoneNumber compara dois números de telefone considerando a equivalência
// do nono dígito para celulares brasileiros (12 dígitos legados vs 13 dígitos normalizados com DDI 55).
func samePhoneNumber(phoneA, phoneB string) bool {
	a := cleanPhoneNumber(phoneA)
	b := cleanPhoneNumber(phoneB)
	if a == b {
		return true
	}
	return matchBrazilPhoneEquivalence(a, b)
}

func matchBrazilPhoneEquivalence(a, b string) bool {
	if a == b {
		return true
	}
	longNum, shortNum := a, b
	if len(a) < len(b) {
		longNum, shortNum = b, a
	}
	if len(longNum) != 13 || len(shortNum) != 12 {
		return false
	}
	if !strings.HasPrefix(longNum, "55") || !strings.HasPrefix(shortNum, "55") {
		return false
	}
	if longNum[2:4] != shortNum[2:4] {
		return false
	}
	if longNum[4] != '9' {
		return false
	}
	// No Brasil, a regra do 9º dígito se aplica exclusivamente a celulares (dígitos locais iniciados por 6, 7, 8 ou 9)
	firstMobileDigit := shortNum[4]
	if firstMobileDigit < '6' || firstMobileDigit > '9' {
		return false
	}
	return longNum[5:] == shortNum[4:]
}
