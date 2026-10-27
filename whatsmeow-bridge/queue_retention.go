package main

import (
	"database/sql"
	"log"
)

// Retenção da fila de webhooks. O payload guarda telefone, texto, legenda e
// nome de arquivo do usuário; nada fica além do necessário para a entrega.
const (
	// Entregues: guardadas 1 h para deduplicar reenvios do WhatsApp.
	sqlDeleteDeliveredQueue = `DELETE FROM webhook_queue
		WHERE delivered_at IS NOT NULL AND created_at < unixepoch() - 3600`
	// Não entregues: processQueue só tenta por 24 h. Depois disso a linha
	// nunca mais seria tentada; antes desta correção, também nunca era
	// apagada, porque só o primeiro pendente tinha attempts incrementado.
	sqlDeleteExpiredQueue = `DELETE FROM webhook_queue
		WHERE delivered_at IS NULL AND created_at < unixepoch() - 86400`
)

// pruneWebhookQueue aplica a retenção da fila e devolve quantas mensagens
// não entregues foram descartadas por idade.
func pruneWebhookQueue(db *sql.DB) int64 {
	if _, err := db.Exec(sqlDeleteDeliveredQueue); err != nil {
		log.Printf("[Fila] Erro ao limpar mensagens entregues: %v", err)
	}
	result, err := db.Exec(sqlDeleteExpiredQueue)
	if err != nil {
		log.Printf("[Fila] Erro ao descartar mensagens expiradas: %v", err)
		return 0
	}
	expired, _ := result.RowsAffected()
	if expired > 0 {
		log.Printf("[Fila] %d mensagem(ns) não entregue(s) em 24 h descartada(s) por retenção", expired)
	}
	return expired
}
