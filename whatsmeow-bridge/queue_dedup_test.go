package main

import (
	"database/sql"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
)

// O evento ao vivo e a recuperação do history sync podem enfileirar a mesma
// mensagem ao mesmo tempo; só uma linha e um POST ao Gleam devem sair.
func TestEnqueueAndDeliverDeduplicaConcorrente(t *testing.T) {
	db, err := sql.Open("sqlite3", "file:"+filepath.Join(t.TempDir(), "q.db")+"?_pragma=busy_timeout(5000)")
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

	var posts atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		posts.Add(1)
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	b := &Bridge{queueDB: db, cfg: Config{Token: testBridgeToken, GleamURL: srv.URL}}
	payload := IncomingWebhook{MessageID: "MSG-DUP", ChatID: "5531999990000@s.whatsapp.net"}

	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if err := b.enqueueAndDeliver(payload); err != nil {
				t.Error(err)
			}
		}()
	}
	wg.Wait()

	var linhas int
	if err := db.QueryRow("SELECT COUNT(*) FROM webhook_queue WHERE message_id = 'MSG-DUP'").Scan(&linhas); err != nil {
		t.Fatal(err)
	}
	if linhas != 1 {
		t.Fatalf("esperava 1 linha na fila, veio %d", linhas)
	}
	if n := posts.Load(); n != 1 {
		t.Fatalf("esperava 1 POST ao Gleam, veio %d", n)
	}
}

func TestEnqueueAndDeliverSemMessageIDNaoDeduplica(t *testing.T) {
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
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	defer srv.Close()
	b := &Bridge{queueDB: db, cfg: Config{Token: testBridgeToken, GleamURL: srv.URL}}

	for i := 0; i < 2; i++ {
		if err := b.enqueueAndDeliver(IncomingWebhook{ChatID: "x@s.whatsapp.net"}); err != nil {
			t.Fatal(err)
		}
	}
	var linhas int
	db.QueryRow("SELECT COUNT(*) FROM webhook_queue").Scan(&linhas)
	if linhas != 2 {
		t.Fatalf("esperava 2 linhas sem message_id, veio %d", linhas)
	}
}
