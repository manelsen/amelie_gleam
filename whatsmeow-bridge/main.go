// Whatsmeow bridge — conecta ao WhatsApp e expõe HTTP para o core Gleam.
//
// Responsabilidades:
//   - Manter a sessão WhatsApp (QR ou Pairing Code)
//   - Receber mensagens e fazer POST /webhook no Gleam
//   - Receber POST /send do Gleam e enviar mensagens ao WhatsApp
//   - GET /health para health check

package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	qrcode "github.com/skip2/go-qrcode"
	"io"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"database/sql"
	moderncsqlite "modernc.org/sqlite"
	"go.mau.fi/whatsmeow"
	waProto "go.mau.fi/whatsmeow/binary/proto"
	"go.mau.fi/whatsmeow/store/sqlstore"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
	waLog "go.mau.fi/whatsmeow/util/log"
	"google.golang.org/protobuf/proto"
)

func init() {
	// Registra modernc.org/sqlite (pure Go, sem CGO) como driver "sqlite3"
	// para compatibilidade com o sqlstore do whatsmeow.
	sql.Register("sqlite3", &moderncsqlite.Driver{})
}

// ---------------------------------------------------------------------------
// Configuração
// ---------------------------------------------------------------------------

type Config struct {
	Port        string // Porta HTTP deste bridge (default: 8080)
	GleamURL    string // URL do webhook Gleam (default: http://localhost:4000/webhook)
	DBPath      string // SQLite para sessão WhatsApp (default: ./db/whatsmeow.db)
	BotPhone    string // Número para Pairing Code (opcional, ativa Pairing Code se definido)
}

func configFromEnv() Config {
	return Config{
		Port:     getEnv("BRIDGE_PORT", "8080"),
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

// ---------------------------------------------------------------------------
// Payload
// ---------------------------------------------------------------------------

// IncomingWebhook é o payload enviado ao Gleam quando uma mensagem chega.
type IncomingWebhook struct {
	ChatID    string `json:"chat_id"`
	From      string `json:"from"`
	MessageID string `json:"message_id,omitempty"`
	Text      string `json:"text"`
	Timestamp int64  `json:"ts"`
	InGroup   bool   `json:"em_grupo"`
	GroupName string `json:"nome_grupo,omitempty"`
	Legenda   string `json:"legenda,omitempty"`
	Tipo      string `json:"tipo"`
	Mime      string `json:"mime,omitempty"`
	Dados     string `json:"dados,omitempty"`
	Caminho   string `json:"caminho_temp,omitempty"`
}

// ReactRequest é o payload recebido do Gleam para enviar uma reação.
type ReactRequest struct {
	ChatID    string `json:"chat_id"`
	MessageID string `json:"message_id"`
	Sender    string `json:"sender"`
	Emoji     string `json:"emoji"`
}

// SendRequest é o payload recebido do Gleam para enviar uma mensagem.
type SendRequest struct {
	ChatID          string `json:"chat_id"`
	Text            string `json:"text"`
	QuotedMessageID string `json:"quoted_message_id,omitempty"`
	QuotedSender    string `json:"quoted_sender,omitempty"`
}

// ---------------------------------------------------------------------------
// Bridge
// ---------------------------------------------------------------------------

// httpClient sem Expect: 100-continue — evita MalformedRequest no Mist
// para payloads binários grandes (áudio, imagem, documento).
var httpClient = &http.Client{
	Transport: &http.Transport{
		ExpectContinueTimeout: 0,
	},
}

type Bridge struct {
	cfg    Config
	client *whatsmeow.Client
}

func NewBridge(cfg Config) (*Bridge, error) {
	dbLog := waLog.Stdout("Database", "WARN", true)
	container, err := sqlstore.New(context.Background(), "sqlite3", "file:"+cfg.DBPath+"?_pragma=foreign_keys(1)", dbLog)
	if err != nil {
		return nil, fmt.Errorf("abrindo banco de dados: %w", err)
	}

	deviceStore, err := container.GetFirstDevice(context.Background())
	if err != nil {
		return nil, fmt.Errorf("obtendo device: %w", err)
	}

	clientLog := waLog.Stdout("Client", "WARN", true)
	client := whatsmeow.NewClient(deviceStore, clientLog)

	return &Bridge{cfg: cfg, client: client}, nil
}

func (b *Bridge) Start() error {
	b.client.AddEventHandler(b.handleEvent)

	if b.client.Store.ID == nil {
		// Não autenticado — QR ou Pairing Code
		if b.cfg.BotPhone != "" {
			return b.loginPairingCode()
		}
		return b.loginQR()
	}

	return b.client.Connect()
}

func (b *Bridge) loginQR() error {
	qrChan, _ := b.client.GetQRChannel(context.Background())
	if err := b.client.Connect(); err != nil {
		return err
	}
	for evt := range qrChan {
		if evt.Event == "code" {
			log.Printf("Novo QR Code gerado. Escaneie no WhatsApp:")
			q, _ := qrcode.New(evt.Code, qrcode.Medium)
			fmt.Println(q.ToSmallString(false))
		} else {
			log.Printf("Auth event: %s\n", evt.Event)
		}
	}
	return nil
}

func (b *Bridge) loginPairingCode() error {
	if err := b.client.Connect(); err != nil {
		return err
	}
	code, err := b.client.PairPhone(context.Background(),b.cfg.BotPhone, true, whatsmeow.PairClientChrome, "Chrome (Linux)")
	if err != nil {
		return fmt.Errorf("pairing code: %w", err)
	}
	log.Printf("Pairing Code: %s\n", code)
	return nil
}

func (b *Bridge) Stop() {
	b.client.Disconnect()
}

// ---------------------------------------------------------------------------
// Recebimento de mensagens
// ---------------------------------------------------------------------------

func (b *Bridge) handleEvent(rawEvt interface{}) {
	switch evt := rawEvt.(type) {
	case *events.Message:
		b.processMessage(evt)
	}
}

func (b *Bridge) processMessage(evt *events.Message) {
	if evt.Info.IsFromMe {
		return
	}

	chatID := evt.Info.Chat.String()
	from := evt.Info.Sender.String()
	inGroup := evt.Info.IsGroup
	timestamp := evt.Info.Timestamp.Unix()

	var groupName string
	if inGroup {
		groupName = evt.Info.PushName
	}

	payload := IncomingWebhook{
		ChatID:    chatID,
		From:      from,
		MessageID: evt.Info.ID,
		Timestamp: timestamp,
		InGroup:   inGroup,
		GroupName: groupName,
	}

	text := extractText(evt.Message)

	if img := evt.Message.GetImageMessage(); img != nil {
		payload.Tipo = "imagem"
		payload.Mime = img.GetMimetype()
		payload.Legenda = img.GetCaption()
		data, err := b.client.Download(context.Background(), img)
		if err == nil {
			payload.Dados = base64.StdEncoding.EncodeToString(data)
		}
	} else if aud := evt.Message.GetAudioMessage(); aud != nil {
		payload.Tipo = "audio"
		payload.Mime = aud.GetMimetype()
		data, err := b.client.Download(context.Background(), aud)
		if err == nil {
			payload.Dados = base64.StdEncoding.EncodeToString(data)
		}
	} else if doc := evt.Message.GetDocumentMessage(); doc != nil {
		// WhatsApp moderno envia imagem/áudio/vídeo como DocumentMessage.
		// Reclassifica pelo MIME type para que o pipeline correto seja usado.
		mime := doc.GetMimetype()
		data, dlErr := b.client.Download(context.Background(), doc)
		switch {
		case strings.HasPrefix(mime, "image/"):
			payload.Tipo = "imagem"
			payload.Mime = mime
			payload.Legenda = doc.GetCaption()
			if dlErr == nil {
				payload.Dados = base64.StdEncoding.EncodeToString(data)
			}
		case strings.HasPrefix(mime, "audio/"):
			payload.Tipo = "audio"
			payload.Mime = mime
			if dlErr == nil {
				payload.Dados = base64.StdEncoding.EncodeToString(data)
			}
		case strings.HasPrefix(mime, "video/"):
			payload.Tipo = "video"
			payload.Mime = mime
			payload.Legenda = doc.GetCaption()
			if dlErr == nil {
				tmpFile, ferr := os.CreateTemp("", "amelie_video_*.mp4")
				if ferr == nil {
					_, _ = tmpFile.Write(data)
					payload.Caminho = tmpFile.Name()
					tmpFile.Close()
				}
			}
		default:
			payload.Tipo = "documento"
			payload.Mime = mime
			payload.Text = doc.GetFileName()
			payload.Legenda = doc.GetCaption()
			if dlErr == nil {
				payload.Dados = base64.StdEncoding.EncodeToString(data)
			}
		}
	} else if vid := evt.Message.GetVideoMessage(); vid != nil {
		payload.Tipo = "video"
		payload.Mime = vid.GetMimetype()
		payload.Legenda = vid.GetCaption()
		data, err := b.client.Download(context.Background(), vid)
		if err == nil {
			tmpFile, err := os.CreateTemp("", "amelie_video_*.mp4")
			if err == nil {
				tmpFile.Write(data)
				payload.Caminho = tmpFile.Name()
				tmpFile.Close()
			}
		}
	} else if evt.Message.GetStickerMessage() != nil {
		return // ignorar adesivos
	} else {
		payload.Tipo = "texto"
		payload.Text = text
	}

	if payload.Tipo == "texto" && payload.Text == "" {
		return // ignora null/empty texto
	}

	log.Printf("Recebida mensagem do tipo: %s, chat: %s", payload.Tipo, chatID)

	if err := b.postToGleam(payload); err != nil {
		log.Printf("Erro ao repassar mensagem ao Gleam: %v\n", err)
	}
}

func extractText(msg *waProto.Message) string {
	if msg == nil {
		return ""
	}
	if msg.Conversation != nil {
		return *msg.Conversation
	}
	if msg.ExtendedTextMessage != nil && msg.ExtendedTextMessage.Text != nil {
		return *msg.ExtendedTextMessage.Text
	}
	return ""
}

func (b *Bridge) postToGleam(payload IncomingWebhook) error {
	data, err := json.Marshal(payload)
	if err != nil {
		return err
	}

	resp, err := httpClient.Post(b.cfg.GleamURL, "application/json", bytes.NewReader(data))
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	io.ReadAll(resp.Body) // drena body
	return nil
}

// ---------------------------------------------------------------------------
// Envio de mensagens (HTTP handler)
// ---------------------------------------------------------------------------

func (b *Bridge) handleSend(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var req SendRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "invalid json", http.StatusBadRequest)
		return
	}

	jid, err := types.ParseJID(req.ChatID)
	if err != nil {
		http.Error(w, "invalid chat_id", http.StatusBadRequest)
		return
	}

	var msg *waProto.Message
	if req.QuotedMessageID != "" && req.QuotedSender != "" {
		msg = &waProto.Message{
			ExtendedTextMessage: &waProto.ExtendedTextMessage{
				Text: proto.String(req.Text),
				ContextInfo: &waProto.ContextInfo{
					StanzaID:    proto.String(req.QuotedMessageID),
					Participant: proto.String(req.QuotedSender),
					QuotedMessage: &waProto.Message{
						Conversation: proto.String(""),
					},
				},
			},
		}
	} else {
		msg = &waProto.Message{
			Conversation: proto.String(req.Text),
		}
	}

	_, err = b.client.SendMessage(context.Background(), jid, msg)
	if err != nil {
		log.Printf("Erro ao enviar mensagem: %v\n", err)
		http.Error(w, "send failed", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.Write([]byte(`{"ok":true}`))
}

func (b *Bridge) handleReact(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var req ReactRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "invalid json", http.StatusBadRequest)
		return
	}

	chatJID, err := types.ParseJID(req.ChatID)
	if err != nil {
		http.Error(w, "invalid chat_id", http.StatusBadRequest)
		return
	}

	msg := &waProto.Message{
		ReactionMessage: &waProto.ReactionMessage{
			Key: &waProto.MessageKey{
				RemoteJID:   proto.String(req.ChatID),
				FromMe:      proto.Bool(false),
				ID:          proto.String(req.MessageID),
				Participant: proto.String(req.Sender),
			},
			Text:              proto.String(req.Emoji),
			SenderTimestampMS: proto.Int64(time.Now().UnixMilli()),
		},
	}

	if _, err := b.client.SendMessage(context.Background(), chatJID, msg); err != nil {
		log.Printf("Erro ao enviar reação: %v\n", err)
		http.Error(w, "react failed", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.Write([]byte(`{"ok":true}`))
}

func handleHealth(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.Write([]byte(`{"status":"ok"}`))
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

func main() {
	cfg := configFromEnv()

	bridge, err := NewBridge(cfg)
	if err != nil {
		log.Fatalf("Falha ao criar bridge: %v\n", err)
	}

	if err := bridge.Start(); err != nil {
		log.Fatalf("Falha ao iniciar conexão WhatsApp: %v\n", err)
	}
	defer bridge.Stop()

	mux := http.NewServeMux()
	mux.HandleFunc("/send", bridge.handleSend)
	mux.HandleFunc("/react", bridge.handleReact)
	mux.HandleFunc("/health", handleHealth)

	server := &http.Server{
		Addr:    ":" + cfg.Port,
		Handler: mux,
	}

	go func() {
		log.Printf("Bridge HTTP escutando na porta %s\n", cfg.Port)
		if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("Servidor HTTP falhou: %v\n", err)
		}
	}()

	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit

	log.Println("Encerrando bridge...")
	server.Shutdown(context.Background())
}
