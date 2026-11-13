package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"time"

	"database/sql"
)

func (b *Bridge) initQueueDB() error {
	dir := filepath.Dir(b.cfg.DBPath)
	dbPath := filepath.Join(dir, "webhook_queue.db")
	db, err := sql.Open("sqlite3", "file:"+dbPath+"?_pragma=journal_mode(WAL)&_pragma=busy_timeout(5000)&_pragma=synchronous(NORMAL)")
	if err != nil {
		return err
	}

	_, err = db.Exec(`CREATE TABLE IF NOT EXISTS webhook_queue (
		id          INTEGER PRIMARY KEY AUTOINCREMENT,
		message_id  TEXT    NOT NULL DEFAULT '',
		payload     TEXT    NOT NULL,
		created_at  INTEGER NOT NULL DEFAULT (unixepoch()),
		attempts    INTEGER NOT NULL DEFAULT 0,
		delivered_at INTEGER
	)`)
	if err != nil {
		db.Close()
		return err
	}

	// Aplica a retenção já na inicialização
	pruneWebhookQueue(db)

	b.queueDB = db
	return nil
}

func (b *Bridge) enqueueAndDeliver(payload IncomingWebhook) error {
	// Único ponto por onde todo payload passa a caminho do Gleam.
	payload.Mime = sanitizeMime(payload.Mime)
	data, err := json.Marshal(payload)
	if err != nil {
		return err
	}

	// Deduplicar: se já existe na fila (entregue ou não), ignorar. Checagem e
	// inserção num só comando, pois o evento ao vivo e a recuperação do
	// history sync podem trazer a mesma mensagem ao mesmo tempo.
	result, err := b.queueDB.Exec(
		`INSERT INTO webhook_queue (message_id, payload)
		 SELECT ?1, ?2 WHERE ?1 = '' OR NOT EXISTS (
		   SELECT 1 FROM webhook_queue WHERE message_id = ?1)`,
		payload.MessageID, string(data),
	)
	if err != nil {
		return fmt.Errorf("fila: erro ao enfileirar: %w", err)
	}
	if n, err := result.RowsAffected(); err == nil && n == 0 {
		// Duplicata: a mídia que esta cópia gravou nunca será lida.
		removeMediaTemp(payload.Caminho)
		return nil
	}

	id, _ := result.LastInsertId()

	if err := b.postToGleam(payload); err != nil {
		log.Printf("[Fila] Mensagem %d enfileirada para retry (erro: %v)", id, err)
		return nil // Enfileirada com sucesso, será retentada
	}

	b.queueDB.Exec("UPDATE webhook_queue SET delivered_at = unixepoch(), attempts = 1 WHERE id = ?", id)
	return nil
}

func (b *Bridge) startQueueWorker() {
	go func() {
		// Tentar entregar pendentes imediatamente ao iniciar
		b.processQueue()

		ticker := time.NewTicker(5 * time.Second)
		defer ticker.Stop()
		cleanTicker := time.NewTicker(1 * time.Hour)
		defer cleanTicker.Stop()

		for {
			select {
			case <-ticker.C:
				b.processQueue()
			case <-cleanTicker.C:
				b.cleanupQueue()
			}
		}
	}()
}

// Linha nova e nunca tentada pela fila é a de um enqueueAndDeliver cujo
// POST direto ainda pode estar em andamento; pegá-la agora entregaria duas
// vezes.
const queueInFlightGraceSeconds = 30

func (b *Bridge) processQueue() {
	rows, err := b.queueDB.Query(
		`SELECT id, payload, attempts FROM webhook_queue
		 WHERE delivered_at IS NULL
		 AND created_at > unixepoch() - 86400
		 AND (attempts > 0 OR created_at <= unixepoch() - ?)
		 ORDER BY id ASC LIMIT 50`,
		queueInFlightGraceSeconds,
	)
	if err != nil {
		log.Printf("[Fila] Erro ao consultar pendentes: %v", err)
		return
	}
	defer rows.Close()

	type pendente struct {
		id       int64
		payload  string
		attempts int
	}
	var pendentes []pendente
	for rows.Next() {
		var p pendente
		if err := rows.Scan(&p.id, &p.payload, &p.attempts); err == nil {
			pendentes = append(pendentes, p)
		}
	}
	rows.Close()

	for _, p := range pendentes {
		var payload IncomingWebhook
		if err := json.Unmarshal([]byte(p.payload), &payload); err != nil {
			log.Printf("[Fila] Payload corrompido id=%d, descartando: %v", p.id, err)
			b.queueDB.Exec("UPDATE webhook_queue SET delivered_at = -1 WHERE id = ?", p.id)
			continue
		}

		err := b.postToGleam(payload)
		switch classifyGleamFailure(err, p.attempts+1) {
		case gleamDelivered:
			b.queueDB.Exec("UPDATE webhook_queue SET delivered_at = unixepoch(), attempts = attempts + 1 WHERE id = ?", p.id)
			log.Printf("[Fila] Mensagem %d entregue com sucesso (msg_id=%s)", p.id, payload.MessageID)
		case gleamRejected:
			// Recusada pelo Gleam: não vai passar em nova tentativa e não pode
			// segurar as mensagens de trás.
			log.Printf("[Fila] Mensagem %d recusada pelo Gleam, descartada (msg_id=%s): %v", p.id, payload.MessageID, err)
			b.queueDB.Exec("UPDATE webhook_queue SET delivered_at = -1, attempts = attempts + 1 WHERE id = ?", p.id)
			removeMediaTemp(payload.Caminho)
		case gleamServerError:
			log.Printf("[Fila] Retry falhou id=%d (tentativa %d de %d); fila parada até o próximo ciclo: %v",
				p.id, p.attempts+1, maxGleamServerErrors, err)
			b.queueDB.Exec("UPDATE webhook_queue SET attempts = attempts + 1 WHERE id = ?", p.id)
			return
		default: // gleamUnavailable
			// Gleam fora do ar (deploy, reinício): espera sem gastar tentativa.
			// Só a retenção de 24 h descarta.
			log.Printf("[Fila] Gleam indisponível, aguardando (id=%d): %v", p.id, err)
			return
		}
	}
}

// Desfecho de uma entrega ao Gleam, para a fila decidir o que fazer com a
// mensagem e com as de trás.
type gleamOutcome int

// Depois de tantos 5xx seguidos, a mensagem é tratada como a causa (derruba
// o handler) e sai da frente das outras.
const maxGleamServerErrors = 20

type gleamStatusError struct {
	status int
	body   string
}

func (e *gleamStatusError) Error() string {
	return fmt.Sprintf("gleam retornou status %d: %s", e.status, e.body)
}

func classifyGleamFailure(err error, attempts int) gleamOutcome {
	if err == nil {
		return gleamDelivered
	}
	var se *gleamStatusError
	if !errors.As(err, &se) {
		return gleamUnavailable
	}
	switch {
	// Só estes apontam para o payload. Os outros 4xx (401, 404 de URL
	// errada, 429...) e 502/503/504 de proxy ou deploy são do caminho até o
	// Gleam: descartar ali perderia mensagens boas.
	case se.status == http.StatusBadRequest, se.status == http.StatusRequestEntityTooLarge,
		se.status == http.StatusUnprocessableEntity:
		return gleamRejected
	case se.status < 500, se.status == http.StatusBadGateway,
		se.status == http.StatusServiceUnavailable, se.status == http.StatusGatewayTimeout:
		return gleamUnavailable
	case attempts >= maxGleamServerErrors:
		return gleamRejected
	default:
		return gleamServerError
	}
}

// removeMediaTemp apaga a mídia temporária de um payload que não vai chegar
// ao Gleam (quem apagaria é o Gleam, depois de ler).
func removeMediaTemp(path string) {
	if path == "" {
		return
	}
	if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
		log.Printf("[Fila] Falha ao remover mídia temporária: %v", err)
	}
}

func (b *Bridge) cleanupQueue() {
	pruneWebhookQueue(b.queueDB)
	b.queueDB.Exec(`PRAGMA wal_checkpoint(TRUNCATE)`)
	b.queueDB.Exec(`PRAGMA optimize`)
	b.queueDB.Exec(`VACUUM`)
	if dir, err := mediaTempDir(); err == nil {
		cleanupOrphanMediaFiles(dir, orphanMediaMaxAge)
	}
}

func (b *Bridge) postToGleam(payload IncomingWebhook) error {
	data, err := json.Marshal(payload)
	if err != nil {
		return err
	}

	resp, err := b.postAuthenticated(b.cfg.GleamURL, data)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 64*1024))
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return &gleamStatusError{status: resp.StatusCode, body: string(body)}
	}
	return nil
}

const (
	gleamDelivered   gleamOutcome = iota
	gleamUnavailable              // transporte, 4xx do caminho, 502/503/504: parar sem contar tentativa
	gleamServerError              // outros 5xx: parar e contar tentativa
	gleamRejected                 // 400/413/422, ou 5xx insistente: descartar e seguir
)
