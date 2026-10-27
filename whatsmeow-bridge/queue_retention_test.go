package main

import (
	"database/sql"
	"path/filepath"
	"testing"
	"time"
)

func TestPruneWebhookQueueDropsExpiredUndelivered(t *testing.T) {
	db, err := sql.Open("sqlite3", "file:"+filepath.Join(t.TempDir(), "q.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if _, err := db.Exec(`CREATE TABLE webhook_queue (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		message_id TEXT NOT NULL DEFAULT '',
		payload TEXT NOT NULL,
		created_at INTEGER NOT NULL DEFAULT (unixepoch()),
		attempts INTEGER NOT NULL DEFAULT 0,
		delivered_at INTEGER)`); err != nil {
		t.Fatal(err)
	}

	now := time.Now().Unix()
	rows := []struct {
		id        string
		created   int64
		attempts  int
		delivered any
	}{
		{"pendente_25h", now - 25*3600, 0, nil},
		{"pendente_recente", now - 600, 0, nil},
		{"entregue_2h", now - 2*3600, 1, now - 2*3600},
		{"entregue_recente", now - 600, 1, now - 590},
	}
	for _, r := range rows {
		if _, err := db.Exec(
			"INSERT INTO webhook_queue (message_id, payload, created_at, attempts, delivered_at) VALUES (?, '{}', ?, ?, ?)",
			r.id, r.created, r.attempts, r.delivered,
		); err != nil {
			t.Fatal(err)
		}
	}

	if expired := pruneWebhookQueue(db); expired != 1 {
		t.Fatalf("esperava 1 expirada, veio %d", expired)
	}

	got := map[string]bool{}
	res, err := db.Query("SELECT message_id FROM webhook_queue")
	if err != nil {
		t.Fatal(err)
	}
	defer res.Close()
	for res.Next() {
		var id string
		if err := res.Scan(&id); err != nil {
			t.Fatal(err)
		}
		got[id] = true
	}
	if len(got) != 2 || !got["pendente_recente"] || !got["entregue_recente"] {
		t.Fatalf("restaram linhas erradas: %v", got)
	}
}
