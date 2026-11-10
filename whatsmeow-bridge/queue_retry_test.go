package main

import (
	"database/sql"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
)

func newQueueTestDB(t *testing.T) *sql.DB {
	t.Helper()
	db, err := sql.Open("sqlite3", "file:"+filepath.Join(t.TempDir(), "q.db")+"?_pragma=busy_timeout(5000)")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	if _, err := db.Exec(`CREATE TABLE webhook_queue (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		message_id TEXT NOT NULL DEFAULT '',
		payload TEXT NOT NULL,
		created_at INTEGER NOT NULL DEFAULT (unixepoch()),
		attempts INTEGER NOT NULL DEFAULT 0,
		delivered_at INTEGER)`); err != nil {
		t.Fatal(err)
	}
	return db
}

// Insere uma linha antiga o bastante para a fila pegar.
func insertQueued(t *testing.T, db *sql.DB, msgID, payload string) int64 {
	t.Helper()
	res, err := db.Exec(
		`INSERT INTO webhook_queue (message_id, payload, created_at) VALUES (?, ?, unixepoch() - 120)`,
		msgID, payload,
	)
	if err != nil {
		t.Fatal(err)
	}
	id, _ := res.LastInsertId()
	return id
}

type queueRow struct {
	attempts  int
	delivered sql.NullInt64
}

func readQueueRow(t *testing.T, db *sql.DB, id int64) queueRow {
	t.Helper()
	var r queueRow
	if err := db.QueryRow("SELECT attempts, delivered_at FROM webhook_queue WHERE id = ?", id).Scan(&r.attempts, &r.delivered); err != nil {
		t.Fatal(err)
	}
	return r
}

// Gleam fora do ar não gasta tentativa: antes, 100 ciclos de 5 s (~8 min)
// bastavam para a mensagem ser abandonada.
func TestProcessQueueGleamForaDoArNaoGastaTentativa(t *testing.T) {
	db := newQueueTestDB(t)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	url := srv.URL
	srv.Close() // conexão recusada

	b := &Bridge{queueDB: db, cfg: Config{Token: testBridgeToken, GleamURL: url}}
	id := insertQueued(t, db, "M1", `{"chat_id":"a@s.whatsapp.net","message_id":"M1"}`)

	for i := 0; i < 3; i++ {
		b.processQueue()
	}
	r := readQueueRow(t, db, id)
	if r.attempts != 0 || r.delivered.Valid {
		t.Fatalf("linha = %+v, esperava pendente sem tentativas", r)
	}
}

// Mensagem recusada (4xx) sai da frente e as de trás seguem no mesmo ciclo.
func TestProcessQueueMensagemRecusadaNaoTravaAFila(t *testing.T) {
	db := newQueueTestDB(t)
	var entregues atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var buf [512]byte
		n, _ := r.Body.Read(buf[:])
		if strings.Contains(string(buf[:n]), "RUIM") {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		entregues.Add(1)
		w.WriteHeader(http.StatusAccepted)
	}))
	defer srv.Close()

	midia := filepath.Join(t.TempDir(), "amelie_midia_imagem_x.jpg")
	if err := os.WriteFile(midia, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}

	b := &Bridge{queueDB: db, cfg: Config{Token: testBridgeToken, GleamURL: srv.URL}}
	ruim := insertQueued(t, db, "RUIM", `{"chat_id":"a@s.whatsapp.net","message_id":"RUIM","caminho_temp":"`+midia+`"}`)
	boa := insertQueued(t, db, "BOA", `{"chat_id":"a@s.whatsapp.net","message_id":"BOA"}`)

	b.processQueue()

	if r := readQueueRow(t, db, ruim); !r.delivered.Valid || r.delivered.Int64 != -1 {
		t.Fatalf("recusada = %+v, esperava descartada (-1)", r)
	}
	if r := readQueueRow(t, db, boa); !r.delivered.Valid || r.delivered.Int64 <= 0 {
		t.Fatalf("boa = %+v, esperava entregue no mesmo ciclo", r)
	}
	if entregues.Load() != 1 {
		t.Fatalf("entregas = %d, esperava 1", entregues.Load())
	}
	if _, err := os.Stat(midia); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("mídia da recusada continua no disco: %v", err)
	}
}

// 5xx conta tentativa e para o ciclo; insistente, a mensagem é tratada como
// a causa e descartada.
func TestProcessQueueErroDoServidorInsistenteDescarta(t *testing.T) {
	db := newQueueTestDB(t)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer srv.Close()

	b := &Bridge{queueDB: db, cfg: Config{Token: testBridgeToken, GleamURL: srv.URL}}
	id := insertQueued(t, db, "M5", `{"chat_id":"a@s.whatsapp.net","message_id":"M5"}`)

	b.processQueue()
	if r := readQueueRow(t, db, id); r.attempts != 1 || r.delivered.Valid {
		t.Fatalf("após 1 ciclo = %+v", r)
	}
	for i := 1; i < maxGleamServerErrors; i++ {
		b.processQueue()
	}
	if r := readQueueRow(t, db, id); !r.delivered.Valid || r.delivered.Int64 != -1 {
		t.Fatalf("após %d ciclos = %+v, esperava descartada", maxGleamServerErrors, r)
	}
}

// Linha recém-criada e nunca tentada é de um POST direto em andamento.
func TestProcessQueueIgnoraEntregaEmVoo(t *testing.T) {
	db := newQueueTestDB(t)
	var posts atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		posts.Add(1)
		w.WriteHeader(http.StatusAccepted)
	}))
	defer srv.Close()

	b := &Bridge{queueDB: db, cfg: Config{Token: testBridgeToken, GleamURL: srv.URL}}
	if _, err := db.Exec(`INSERT INTO webhook_queue (message_id, payload) VALUES ('NOVA', '{}')`); err != nil {
		t.Fatal(err)
	}
	b.processQueue()
	if posts.Load() != 0 {
		t.Fatal("fila pegou linha com entrega direta em andamento")
	}
}

// Duplicata descartada pela fila não deixa a mídia que gravou no disco.
func TestEnqueueDuplicataRemoveMidia(t *testing.T) {
	db := newQueueTestDB(t)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusAccepted)
	}))
	defer srv.Close()
	b := &Bridge{queueDB: db, cfg: Config{Token: testBridgeToken, GleamURL: srv.URL}}

	if err := b.enqueueAndDeliver(IncomingWebhook{MessageID: "D1", ChatID: "a@s.whatsapp.net"}); err != nil {
		t.Fatal(err)
	}
	midia := filepath.Join(t.TempDir(), "amelie_midia_imagem_dup.jpg")
	if err := os.WriteFile(midia, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := b.enqueueAndDeliver(IncomingWebhook{MessageID: "D1", ChatID: "a@s.whatsapp.net", Caminho: midia}); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(midia); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("mídia da duplicata continua no disco: %v", err)
	}
}

func TestClassifyGleamFailure(t *testing.T) {
	casos := []struct {
		err      error
		attempts int
		want     gleamOutcome
	}{
		{nil, 1, gleamDelivered},
		{errors.New("connection refused"), 1, gleamUnavailable},
		{&gleamStatusError{status: 401}, 1, gleamUnavailable},
		{&gleamStatusError{status: 404}, 1, gleamUnavailable},
		{&gleamStatusError{status: 429}, 1, gleamUnavailable},
		{&gleamStatusError{status: 400}, 1, gleamRejected},
		{&gleamStatusError{status: 413}, 1, gleamRejected},
		{&gleamStatusError{status: 422}, 1, gleamRejected},
		{&gleamStatusError{status: 500}, 1, gleamServerError},
		{&gleamStatusError{status: 500}, maxGleamServerErrors, gleamRejected},
		{&gleamStatusError{status: 503}, maxGleamServerErrors, gleamUnavailable},
		{&gleamStatusError{status: 502}, 1, gleamUnavailable},
		{&gleamStatusError{status: 504}, 1, gleamUnavailable},
	}
	for _, c := range casos {
		if got := classifyGleamFailure(c.err, c.attempts); got != c.want {
			t.Errorf("classifyGleamFailure(%v, %d) = %v, want %v", c.err, c.attempts, got, c.want)
		}
	}
}
