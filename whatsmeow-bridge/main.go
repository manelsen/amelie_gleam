// Whatsmeow bridge — conecta ao WhatsApp e expõe HTTP para o core Gleam.
//
// Responsabilidades:
//   - Manter a sessão WhatsApp (QR ou Pairing Code)
//   - Receber mensagens e fazer POST /webhook no Gleam
//   - Receber POST /send do Gleam e enviar mensagens ao WhatsApp
//   - GET /health para health check
//
// Este arquivo tem a ponte em si (Bridge, início, sessão) e o main. O resto:
//   - config.go: configuração e normalização de telefone
//   - payloads.go: JSON trocado com o Gleam
//   - connection.go: eventos do WhatsApp e estado da conexão
//   - incoming.go: mensagem recebida → payload do webhook
//   - media.go, sticker.go: download, retry e conversão de mídia
//   - webhook_queue.go: fila persistente de entrega ao Gleam
//   - gleam_events.go: avisos de queda, volta e pareamento ao Gleam
//   - http_handlers.go: rotas HTTP (/send, /react, /health, pareamento, reset)

package main

import (
	"context"
	"fmt"
	qrcode "github.com/skip2/go-qrcode"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"database/sql"
	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/store/sqlstore"
	"go.mau.fi/whatsmeow/types"
	waLog "go.mau.fi/whatsmeow/util/log"
	moderncsqlite "modernc.org/sqlite"
)

func init() {
	// Registra modernc.org/sqlite (pure Go) como driver "sqlite3"
	// para compatibilidade com o sqlstore do whatsmeow.
	sql.Register("sqlite3", &moderncsqlite.Driver{})
}

// ---------------------------------------------------------------------------
// Bridge
// ---------------------------------------------------------------------------

// httpClient sem Expect: 100-continue — evita MalformedRequest no Mist
// para payloads binários grandes (áudio, imagem, documento).
var httpClient = &http.Client{
	Timeout:       20 * time.Second,
	CheckRedirect: func(_ *http.Request, _ []*http.Request) error { return http.ErrUseLastResponse },
	Transport: &http.Transport{
		ExpectContinueTimeout: 0,
	},
}

type Bridge struct {
	cfg       Config
	container *sqlstore.Container
	clientLog waLog.Logger
	// client é trocado no reset de sessão enquanto handlers HTTP e eventos o
	// leem em outras goroutines: leitura só por wa(), troca só sob clientMu.
	client   *whatsmeow.Client
	clientMu sync.RWMutex
	// resetMu serializa deleteSessionStore inteiro: dois resets juntos
	// (LoggedOut e /reset) apagariam o mesmo dispositivo e criariam dois.
	resetMu             sync.Mutex
	connectionMu        sync.RWMutex
	lastConnectionError *APIError
	retryMu             sync.Mutex
	pendingMediaRetries map[string]mediaRetryPending
	mediaRetryAttempts  map[string]int
	queueDB             *sql.DB
	groupLeaves         *leaveAttempts
	historyMu           sync.Mutex
	historySeen         map[types.MessageID]struct{}
	pairingMu           sync.Mutex
	pairingGen          uint64
	pairingStop         chan struct{}
	dispatch            chatDispatcher
	// avisoQuedaPendente fica verdadeiro quando um aviso de queda
	// (whatsapp_down ou código de pareamento) entra na fila e a volta ainda
	// não foi avisada. A ponte nasce com ele ligado: subir o processo também
	// é uma volta. Se o aviso de queda se perder, a volta sai mesmo assim; um
	// "voltou" a mais é melhor que nenhum.
	avisoQuedaPendente atomic.Bool
	eventosMu          sync.Mutex
	// geracaoVolta numera cada whatsapp_up enfileirado (sob eventosMu). Só
	// a falha do aviso mais recente religa a pendência: um aviso antigo que
	// desiste depois de outro já ter saído geraria uma volta duplicada.
	geracaoVolta uint64
	eventos      chan eventoGleam
}

func NewBridge(cfg Config) (*Bridge, error) {
	dbLog := waLog.Stdout("Database", "WARN", true)
	container, err := sqlstore.New(context.Background(), "sqlite3", "file:"+cfg.DBPath+"?_pragma=foreign_keys(1)&_pragma=busy_timeout(60000)&_pragma=journal_mode(WAL)&_pragma=synchronous(NORMAL)", dbLog)
	if err != nil {
		return nil, fmt.Errorf("abrindo banco de dados: %w", err)
	}

	deviceStore, err := container.GetFirstDevice(context.Background())
	if err != nil {
		return nil, fmt.Errorf("obtendo device: %w", err)
	}

	clientLog := waLog.Stdout("Client", "INFO", true)
	client := whatsmeow.NewClient(deviceStore, clientLog)

	b := &Bridge{
		cfg:                 cfg,
		container:           container,
		clientLog:           clientLog,
		client:              client,
		pendingMediaRetries: make(map[string]mediaRetryPending),
		mediaRetryAttempts:  make(map[string]int),
		groupLeaves:         newLeaveAttempts(),
	}
	b.avisoQuedaPendente.Store(true)

	if err := b.initQueueDB(); err != nil {
		return nil, fmt.Errorf("inicializando fila de webhook: %w", err)
	}

	return b, nil
}

func (b *Bridge) Start() error {
	b.wa().AddEventHandler(b.handleEvent)
	b.startQueueWorker()

	phone := cleanPhoneNumber(b.cfg.BotPhone)
	if id := b.wa().Store.ID; phone != "" && id != nil && !samePhoneNumber(id.User, phone) {
		log.Printf("[WhatsApp] MOBILE_NUMBER (%s) difere da sessão salva (%s). Limpando sessão anterior para novo pareamento.", maskID(phone), maskID(id.User))
		b.deleteSessionStore()
	}

	if b.wa().Store.ID == nil {
		// Não autenticado — QR ou Pairing Code
		if phone != "" {
			return b.loginPairingCode()
		}
		return b.loginQR()
	}

	return b.wa().Connect()
}

func (b *Bridge) loginQR() error {
	c := b.wa()
	qrChan, _ := c.GetQRChannel(context.Background())
	if err := c.Connect(); err != nil {
		return err
	}
	for evt := range qrChan {
		if evt.Event == "code" {
			log.Printf("Novo QR Code gerado. Escaneie no WhatsApp:")
			q, _ := qrcode.New(evt.Code, qrcode.Medium)
			fmt.Println(q.ToSmallString(false))
		} else {
			log.Printf("Auth event: %s\n", evt.Event)
			if evt.Event == "timeout" {
				return fmt.Errorf("QR code expirou sem ser escaneado — reiniciando para gerar novo")
			}
		}
	}
	return nil
}

func (b *Bridge) loginPairingCode() error {
	phone := cleanPhoneNumber(b.cfg.BotPhone)
	if phone == "" {
		return fmt.Errorf("MOBILE_NUMBER não configurado ou inválido para pairing code")
	}
	_, err := b.requestPairingCode(phone)
	return err
}

func (b *Bridge) Stop() {
	b.wa().Disconnect()
	if b.queueDB != nil {
		b.queueDB.Close()
	}
}

// wa devolve o cliente atual do WhatsApp. Quem usa o cliente várias vezes
// seguidas guarda o retorno numa variável, para não misturar o antigo e o
// novo se um reset acontecer no meio.
func (b *Bridge) wa() *whatsmeow.Client {
	b.clientMu.RLock()
	defer b.clientMu.RUnlock()
	return b.client
}

func (b *Bridge) deleteSessionStore() {
	b.resetMu.Lock()
	defer b.resetMu.Unlock()
	if old := b.wa(); old != nil {
		if old.IsConnected() {
			old.Disconnect()
		}
		if old.Store != nil && old.Store.Container != nil {
			_ = old.Store.Delete(context.Background())
		}
	}
	if b.container != nil {
		novo := whatsmeow.NewClient(b.container.NewDevice(), b.clientLog)
		novo.AddEventHandler(b.handleEvent)
		b.clientMu.Lock()
		b.client = novo
		b.clientMu.Unlock()
	} else if c := b.wa(); c != nil && c.Store != nil {
		c.Store.ID = nil
	}
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

func main() {
	cfg := configFromEnv()
	if len(cfg.Token) < 32 {
		log.Fatal("Defina BRIDGE_TOKEN com pelo menos 32 caracteres aleatórios")
	}
	if _, err := mediaTempDir(); err != nil {
		log.Fatalf("Diretório de mídia inválido: %v", err)
	}

	bridge, err := NewBridge(cfg)
	if err != nil {
		log.Fatalf("Falha ao criar bridge: %v\n", err)
	}

	server := &http.Server{
		Addr:              net.JoinHostPort(cfg.Host, cfg.Port),
		Handler:           bridge.routes(),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      120 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	go func() {
		log.Printf("Bridge HTTP escutando na porta %s\n", cfg.Port)
		if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("Servidor HTTP falhou: %v\n", err)
		}
	}()

	go func() {
		if err := bridge.Start(); err != nil {
			log.Printf("[WhatsApp] Aviso na inicialização do WhatsApp: %v\n", err)
		}
	}()

	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit

	log.Println("Encerrando bridge...")
	server.Shutdown(context.Background())
}
