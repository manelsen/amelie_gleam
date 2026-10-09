// Whatsmeow bridge — conecta ao WhatsApp e expõe HTTP para o core Gleam.
//
// Responsabilidades:
//   - Manter a sessão WhatsApp (QR ou Pairing Code)
//   - Receber mensagens e fazer POST /webhook no Gleam
//   - Receber POST /send do Gleam e enviar mensagens ao WhatsApp
//   - GET /health para health check

package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	qrcode "github.com/skip2/go-qrcode"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	osExec "os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"database/sql"
	"go.mau.fi/whatsmeow"
	waProto "go.mau.fi/whatsmeow/binary/proto"
	waMmsRetry "go.mau.fi/whatsmeow/proto/waMmsRetry"
	"go.mau.fi/whatsmeow/store/sqlstore"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
	waLog "go.mau.fi/whatsmeow/util/log"
	"google.golang.org/protobuf/proto"
	moderncsqlite "modernc.org/sqlite"
)

func init() {
	// Registra modernc.org/sqlite (pure Go) como driver "sqlite3"
	// para compatibilidade com o sqlstore do whatsmeow.
	sql.Register("sqlite3", &moderncsqlite.Driver{})
}

// ---------------------------------------------------------------------------
// Configuração
// ---------------------------------------------------------------------------

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
// Remove caracteres não-numéricos, zeros à esquerda e adiciona DDI 55 para números brasileiros de 10/11 dígitos.
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
	return cleaned
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

type APIError struct {
	Code      string `json:"code"`
	Message   string `json:"error"`
	Timestamp string `json:"timestamp,omitempty"`
}

type ErrorResponse struct {
	OK bool `json:"ok"`
	APIError
}

type HealthResponse struct {
	Status   string `json:"status"`
	LoggedIn bool   `json:"logged_in"`
	*APIError
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
	cfg                 Config
	container           *sqlstore.Container
	clientLog           waLog.Logger
	client              *whatsmeow.Client
	connectionMu        sync.RWMutex
	lastConnectionError *APIError
	retryMu             sync.Mutex
	pendingMediaRetries map[string]mediaRetryPending
	mediaRetryAttempts  map[string]int
	queueDB             *sql.DB
}

type mediaRetryPending struct {
	event           *events.Message
	kind            string
	mediaKey        []byte
	applyDirectPath func(string)
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
	}

	if err := b.initQueueDB(); err != nil {
		return nil, fmt.Errorf("inicializando fila de webhook: %w", err)
	}

	return b, nil
}

func (b *Bridge) Start() error {
	b.client.AddEventHandler(b.handleEvent)
	b.startQueueWorker()

	phone := cleanPhoneNumber(b.cfg.BotPhone)
	if phone != "" && b.client.Store.ID != nil && b.client.Store.ID.User != phone {
		log.Printf("[WhatsApp] MOBILE_NUMBER (%s) difere da sessão salva (%s). Limpando sessão anterior para novo pareamento.", phone, b.client.Store.ID.User)
		b.deleteSessionStore()
	}

	if b.client.Store.ID == nil {
		// Não autenticado — QR ou Pairing Code
		if phone != "" {
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

	qrChan, _ := b.client.GetQRChannel(context.Background())
	if err := b.client.Connect(); err != nil {
		return fmt.Errorf("falha ao conectar websocket para pairing code: %w", err)
	}

	// Aguarda o primeiro evento do canal para garantir que a conexão websocket está pronta
	select {
	case evt, ok := <-qrChan:
		if !ok {
			return fmt.Errorf("canal de autenticação fechou antes do pareamento")
		}
		if evt.Event == "success" {
			log.Println("[WhatsApp] Já autenticado com sucesso!")
			return nil
		}
	case <-time.After(5 * time.Second):
		// Timeout de segurança caso o evento demore
	}

	code, err := b.client.PairPhone(context.Background(), phone, true, whatsmeow.PairClientChrome, "Chrome (Linux)")
	if err != nil {
		return fmt.Errorf("falha ao gerar pairing code para %s: %w", phone, err)
	}

	b.notifyGleamEvent(map[string]interface{}{
		"evento": "pairing_code",
		"phone":  phone,
		"code":   code,
	})

	log.Println("==================================================")
	log.Printf("📱 PAIRING CODE GERADO PARA %s: %s\n", phone, code)
	log.Println("👉 No WhatsApp do celular:")
	log.Println("   Aparelhos conectados > Conectar com número de telefone")
	log.Printf("   e digite o código: %s\n", code)
	log.Println("==================================================")

	for evt := range qrChan {
		switch evt.Event {
		case "success":
			log.Printf("[WhatsApp] Autenticação via Pairing Code realizada com sucesso!")
			return nil
		case "timeout":
			log.Printf("[WhatsApp] Pairing code expirou sem ser confirmado no celular. Aguardando nova solicitação via /parear...")
			b.setConnectionError("pairing_timeout", "pairing code expirou sem confirmação no celular")
			return nil
		default:
			log.Printf("[WhatsApp] Evento de autenticação: %s\n", evt.Event)
		}
	}
	return nil
}

func (b *Bridge) Stop() {
	b.client.Disconnect()
	if b.queueDB != nil {
		b.queueDB.Close()
	}
}

// ---------------------------------------------------------------------------
// Recebimento de mensagens
// ---------------------------------------------------------------------------

func (b *Bridge) handleEvent(rawEvt interface{}) {
	switch evt := rawEvt.(type) {
	case *events.Message:
		b.processMessage(evt)
	case *events.MediaRetry:
		b.handleMediaRetry(evt)
	case *events.Connected:
		b.clearConnectionError()
		log.Printf("[WhatsApp] Conectado e autenticado")
	case *events.Disconnected:
		b.setConnectionError(
			"whatsapp_disconnected",
			"websocket fechado pelo servidor; aguardando reconexão automática",
		)
	case *events.LoggedOut:
		b.setConnectionError(
			"whatsapp_logged_out",
			fmt.Sprintf(
				"sessão removida pelo WhatsApp (%s, ao_conectar=%t); novo pareamento necessário",
				evt.Reason.String(),
				evt.OnConnect,
			),
		)
		phone := b.cfg.BotPhone
		if phone == "" && b.client.Store.ID != nil {
			phone = b.client.Store.ID.User
		}
		b.deleteSessionStore()

		if phone != "" {
			go func(targetPhone string) {
				time.Sleep(3 * time.Second)
				log.Printf("[WhatsApp] Sessão caiu. Tentando gerar novo pairing code para %s...\n", targetPhone)
				code, err := b.requestPairingCode(targetPhone)
				if err != nil {
					log.Printf("[WhatsApp] Erro ao gerar pairing code pós-logout: %v\n", err)
					b.notifyGleamEvent(map[string]interface{}{
						"evento": "whatsapp_down",
						"motivo": fmt.Sprintf("Sessão desconectada. Falha ao gerar pairing code: %v", err),
					})
				} else {
					log.Printf("[WhatsApp] Novo pairing code pós-logout gerado: %s\n", code)
				}
			}(phone)
		} else {
			b.notifyGleamEvent(map[string]interface{}{
				"evento": "whatsapp_down",
				"motivo": "Sessão removida pelo WhatsApp",
			})
		}
	case *events.StreamReplaced:
		b.setConnectionError(
			"whatsapp_stream_replaced",
			"sessão substituída por outra conexão usando as mesmas credenciais",
		)
	case *events.ConnectFailure:
		b.setConnectionError(
			"whatsapp_connect_failure",
			fmt.Sprintf("falha de conexão %s: %s", evt.Reason.String(), evt.Message),
		)
	case *events.StreamError:
		b.setConnectionError(
			"whatsapp_stream_error",
			fmt.Sprintf("erro de stream não reconhecido (código %s)", evt.Code),
		)
	case *events.ClientOutdated:
		b.setConnectionError(
			"whatsapp_client_outdated",
			"cliente whatsmeow rejeitado como desatualizado",
		)
	case *events.CATRefreshError:
		b.setConnectionError(
			"whatsapp_cat_refresh_failed",
			fmt.Sprintf("falha ao renovar token de autenticação: %v", evt.Error),
		)
	case *events.TemporaryBan:
		b.setConnectionError(
			"whatsapp_temporarily_banned",
			evt.String(),
		)
	case *events.PairError:
		b.setConnectionError(
			"whatsapp_pair_failed",
			fmt.Sprintf("falha ao concluir pareamento: %v", evt.Error),
		)
	case *events.PairSuccess:
		log.Printf("[WhatsApp] Pareamento concluído; aguardando conexão autenticada")
	case *events.KeepAliveTimeout:
		log.Printf(
			"[WhatsApp] Keepalive expirou: erros=%d último_sucesso=%s",
			evt.ErrorCount,
			evt.LastSuccess.Format(time.RFC3339),
		)
	case *events.KeepAliveRestored:
		log.Printf("[WhatsApp] Keepalive restabelecido")
	case *events.NotifyAccountReachoutTimelock:
		log.Printf(
			"[WhatsApp] Restrição de alcance: ativa=%t tipo=%s término=%v",
			evt.IsActive,
			evt.EnforcementType,
			evt.TimeEnforcementEnds,
		)
	}
}

func (b *Bridge) setConnectionError(code, message string) {
	connectionError := &APIError{
		Code:      code,
		Message:   message,
		Timestamp: time.Now().Format(time.RFC3339),
	}
	b.connectionMu.Lock()
	b.lastConnectionError = connectionError
	b.connectionMu.Unlock()
	log.Printf("[WhatsApp] INDISPONÍVEL [%s]: %s", code, message)
}

func (b *Bridge) clearConnectionError() {
	b.connectionMu.Lock()
	b.lastConnectionError = nil
	b.connectionMu.Unlock()
}

func (b *Bridge) currentConnectionError() *APIError {
	b.connectionMu.RLock()
	defer b.connectionMu.RUnlock()
	if b.lastConnectionError == nil {
		return nil
	}
	copy := *b.lastConnectionError
	return &copy
}

func (b *Bridge) availabilityError() *APIError {
	if connectionError := b.currentConnectionError(); connectionError != nil {
		return connectionError
	}
	if b.client == nil || b.client.Store == nil {
		return &APIError{
			Code:    "whatsapp_client_unavailable",
			Message: "cliente whatsmeow não inicializado",
		}
	}
	if b.client.Store.ID == nil {
		return &APIError{
			Code:    "whatsapp_session_missing",
			Message: "sessão WhatsApp ausente; novo pareamento necessário",
		}
	}
	if !b.client.IsConnected() {
		return &APIError{
			Code:    "whatsapp_disconnected",
			Message: "cliente WhatsApp desconectado ou ainda não autenticado",
		}
	}
	if !b.client.IsLoggedIn() {
		return &APIError{
			Code:    "whatsapp_unauthenticated",
			Message: "cliente WhatsApp conectado mas não autenticado",
		}
	}
	return nil
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
		data, ok := b.downloadMediaBytes(evt, "imagem", payload.Mime, "", img, func(path string) {
			img.URL = nil
			img.DirectPath = proto.String(path)
		})
		if !ok {
			return
		}
		if !b.attachMediaFile(&payload, "imagem", "", data) {
			return
		}
	} else if aud := evt.Message.GetAudioMessage(); aud != nil {
		payload.Tipo = "audio"
		payload.Mime = aud.GetMimetype()
		data, ok := b.downloadMediaBytes(evt, "audio", payload.Mime, "", aud, func(path string) {
			aud.URL = nil
			aud.DirectPath = proto.String(path)
		})
		if !ok {
			return
		}
		if !b.attachMediaFile(&payload, "audio", "", data) {
			return
		}
	} else if doc := evt.Message.GetDocumentMessage(); doc != nil {
		// WhatsApp moderno envia imagem/áudio/vídeo como DocumentMessage.
		// Reclassifica pelo MIME type e, quando ele vier genérico, pelo nome do arquivo.
		fileName := doc.GetFileName()
		mediaType, mime := classifyDocumentMedia(doc.GetMimetype(), fileName)
		switch mediaType {
		case "imagem":
			payload.Tipo = "imagem"
			payload.Mime = mime
			payload.Legenda = doc.GetCaption()
			data, ok := b.downloadMediaBytes(evt, "imagem", mime, fileName, doc, func(path string) {
				doc.URL = nil
				doc.DirectPath = proto.String(path)
			})
			if !ok {
				return
			}
			if !b.attachMediaFile(&payload, "imagem", "", data) {
				return
			}
		case "audio":
			payload.Tipo = "audio"
			payload.Mime = mime
			data, ok := b.downloadMediaBytes(evt, "audio", mime, fileName, doc, func(path string) {
				doc.URL = nil
				doc.DirectPath = proto.String(path)
			})
			if !ok {
				return
			}
			if !b.attachMediaFile(&payload, "audio", "", data) {
				return
			}
		case "video":
			payload.Tipo = "video"
			payload.Mime = mime
			payload.Legenda = doc.GetCaption()
			data, ok := b.downloadMediaBytes(evt, "video", mime, fileName, doc, func(path string) {
				doc.URL = nil
				doc.DirectPath = proto.String(path)
			})
			if !ok {
				return
			}
			if !b.attachMediaFile(&payload, "video", ".mp4", data) {
				return
			}
		default:
			payload.Tipo = "documento"
			payload.Mime = mime
			payload.Text = fileName
			payload.Legenda = doc.GetCaption()
			data, ok := b.downloadMediaBytes(evt, "documento", mime, fileName, doc, func(path string) {
				doc.URL = nil
				doc.DirectPath = proto.String(path)
			})
			if !ok {
				return
			}
			if !b.attachMediaFile(&payload, "documento", "", data) {
				return
			}
		}
	} else if vid := evt.Message.GetVideoMessage(); vid != nil {
		payload.Tipo = "video"
		payload.Mime = vid.GetMimetype()
		payload.Legenda = vid.GetCaption()
		data, ok := b.downloadMediaBytes(evt, "video", payload.Mime, "", vid, func(path string) {
			vid.URL = nil
			vid.DirectPath = proto.String(path)
		})
		if !ok {
			return
		}
		if !b.attachMediaFile(&payload, "video", ".mp4", data) {
			return
		}
	} else if sticker := evt.Message.GetStickerMessage(); sticker != nil {
		payload.Tipo = "sticker"
		payload.Mime = normalizeStickerMime(sticker.GetMimetype())
		payload.Legenda = stickerPromptContext(sticker)
		log.Printf("Figurinha recebida: chat=%s mensagem=%s mime=%s animada=%v", chatID, evt.Info.ID, payload.Mime, sticker.GetIsAnimated())
		applyDirectPath := func(path string) {
			sticker.URL = nil
			sticker.DirectPath = proto.String(path)
		}
		data, ok := b.downloadStickerBytes(evt, payload.Mime, sticker, applyDirectPath)
		if !ok {
			if b.hasPendingMediaRetry(evt.Info.Chat, evt.Info.ID) {
				b.scheduleStickerMetadataFallback(payload, sticker, evt.Info.Chat, evt.Info.ID)
				return
			}

			fallbackData, fallbackMime, fallbackOK := stickerThumbnailFallback(sticker)
			if fallbackOK {
				data = fallbackData
				payload.Mime = fallbackMime
				log.Printf("Usando thumbnail PNG da figurinha como fallback: chat=%s mensagem=%s", chatID, evt.Info.ID)
			} else {
				log.Printf("Figurinha sem dados e sem thumbnail: chat=%s mensagem=%s mime=%s animada=%v", chatID, evt.Info.ID, payload.Mime, sticker.GetIsAnimated())
				if err := b.enqueueAndDeliver(stickerMetadataFallbackPayload(payload, sticker)); err != nil {
					log.Printf("Erro ao enfileirar fallback textual de figurinha: chat=%s mensagem=%s erro=%v", chatID, evt.Info.ID, err)
				}
				return
			}
		}
		if sticker.GetIsAnimated() {
			if videoPath, convOK := convertAnimatedStickerToMP4(data); convOK {
				payload.Tipo = "video"
				payload.Mime = "video/mp4"
				payload.Caminho = videoPath
				payload.Dados = ""
				log.Printf("Figurinha animada convertida para MP4: chat=%s mensagem=%s caminho=%s", chatID, evt.Info.ID, videoPath)
			} else if sheet, sheetMime, sheetOK := convertAnimatedStickerToContactSheet(data); sheetOK {
				data = sheet
				payload.Mime = sheetMime
				log.Printf("Figurinha animada convertida em grade de quadros: chat=%s mensagem=%s bytes=%d", chatID, evt.Info.ID, len(data))
			} else {
				log.Printf("Figurinha animada será processada como sticker WebP: chat=%s mensagem=%s", chatID, evt.Info.ID)
			}
		}
		if payload.Caminho == "" && !b.attachMediaFile(&payload, "sticker", "", data) {
			return
		}
	} else {
		payload.Tipo = "texto"
		payload.Text = text
	}

	if payload.Tipo == "texto" && payload.Text == "" {
		return // ignora null/empty texto
	}

	if err := b.enqueueAndDeliver(payload); err != nil {
		log.Printf("Erro ao enfileirar mensagem: %v\n", err)
		b.clearMediaRetryState(evt.Info.Chat, evt.Info.ID)
		return
	}
	b.clearMediaRetryState(evt.Info.Chat, evt.Info.ID)
}

func (b *Bridge) downloadMediaBytes(
	evt *events.Message,
	kind string,
	mime string,
	fileName string,
	msg whatsmeow.DownloadableMessage,
	applyDirectPath func(string),
) ([]byte, bool) {
	// Fail fast para domínios fantasmas do WhatsApp que causam delays de 15s
	ctx, cancel := context.WithTimeout(context.Background(), mediaDownloadTimeout(kind))
	defer cancel()

	data, err := b.client.Download(ctx, msg)
	if err == nil {
		if len(data) == 0 {
			log.Printf("%s vazio recebido do WhatsApp: chat=%s mime=%s arquivo=%q", kind, evt.Info.Chat.String(), mime, fileName)
			return nil, false
		}
		return data, true
	}

	if shouldRequestMediaRetry(err) {
		if retryErr := b.requestMediaRetry(evt, kind, msg.GetMediaKey(), applyDirectPath); retryErr != nil {
			log.Printf("Falha ao solicitar media retry para %s: chat=%s mime=%s arquivo=%q erro_download=%v erro_retry=%v", kind, evt.Info.Chat.String(), mime, fileName, err, retryErr)
			b.clearMediaRetryState(evt.Info.Chat, evt.Info.ID)
		} else {
			log.Printf("Media retry solicitado para %s: chat=%s mime=%s arquivo=%q erro_download=%v", kind, evt.Info.Chat.String(), mime, fileName, err)
		}
		return nil, false
	}

	// Se for erro de conexão ou timeout curto, não insiste 15s
	if strings.Contains(err.Error(), "connection refused") || strings.Contains(err.Error(), "context deadline exceeded") {
		log.Printf("Download de %s abortado rapidamente: chat=%s mime=%s arquivo=%q erro=%v", kind, evt.Info.Chat.String(), mime, fileName, err)
		return nil, false
	}

	log.Printf("Falha ao baixar %s do WhatsApp: chat=%s mime=%s arquivo=%q erro=%v", kind, evt.Info.Chat.String(), mime, fileName, err)
	return nil, false
}

func (b *Bridge) downloadStickerBytes(
	evt *events.Message,
	mime string,
	sticker *waProto.StickerMessage,
	applyDirectPath func(string),
) ([]byte, bool) {
	if sticker.GetDirectPath() != "" {
		ctx, cancel := context.WithTimeout(context.Background(), mediaDownloadTimeout("figurinha"))
		defer cancel()

		data, err := b.client.DownloadMediaWithPath(
			ctx,
			sticker.GetDirectPath(),
			sticker.GetFileEncSHA256(),
			sticker.GetFileSHA256(),
			sticker.GetMediaKey(),
			whatsmeow.MediaImage,
			"sticker",
			false,
		)
		if err == nil {
			if len(data) == 0 {
				log.Printf("figurinha vazia recebida do WhatsApp com mms-type=sticker: chat=%s mime=%s", evt.Info.Chat.String(), mime)
				return nil, false
			}
			log.Printf("Figurinha baixada com mms-type=sticker: chat=%s mensagem=%s bytes=%d", evt.Info.Chat.String(), evt.Info.ID, len(data))
			return data, true
		}
		log.Printf("Falha ao baixar figurinha com mms-type=sticker: chat=%s mensagem=%s mime=%s erro=%v", evt.Info.Chat.String(), evt.Info.ID, mime, err)
	}

	return b.downloadMediaBytes(evt, "figurinha", mime, "", sticker, applyDirectPath)
}

func mediaDownloadTimeout(kind string) time.Duration {
	if kind == "figurinha" {
		return 8 * time.Second
	}
	return 2 * time.Second
}

func (b *Bridge) requestMediaRetry(
	evt *events.Message,
	kind string,
	mediaKey []byte,
	applyDirectPath func(string),
) error {
	if len(mediaKey) == 0 {
		return fmt.Errorf("media key ausente")
	}

	key := mediaRetryKey(evt.Info.Chat, evt.Info.ID)

	b.retryMu.Lock()
	if b.mediaRetryAttempts[key] >= 1 {
		b.retryMu.Unlock()
		return fmt.Errorf("media retry ja tentado para a mensagem %s", evt.Info.ID)
	}
	b.mediaRetryAttempts[key] = 1
	b.pendingMediaRetries[key] = mediaRetryPending{
		event:           evt,
		kind:            kind,
		mediaKey:        mediaKey,
		applyDirectPath: applyDirectPath,
	}
	b.retryMu.Unlock()

	if err := b.client.SendMediaRetryReceipt(context.Background(), &evt.Info, mediaKey); err != nil {
		b.clearMediaRetryState(evt.Info.Chat, evt.Info.ID)
		return err
	}

	return nil
}

func (b *Bridge) handleMediaRetry(evt *events.MediaRetry) {
	key := mediaRetryKey(evt.ChatID, evt.MessageID)

	b.retryMu.Lock()
	pending, ok := b.pendingMediaRetries[key]
	if ok {
		delete(b.pendingMediaRetries, key)
	}
	b.retryMu.Unlock()

	if !ok {
		log.Printf("Media retry recebido sem contexto local: chat=%s mensagem=%s", evt.ChatID.String(), evt.MessageID)
		return
	}

	retryData, err := whatsmeow.DecryptMediaRetryNotification(evt, pending.mediaKey)
	if err != nil {
		log.Printf("Falha ao descriptografar media retry de %s: chat=%s mensagem=%s erro=%v", pending.kind, evt.ChatID.String(), evt.MessageID, err)
		b.clearMediaRetryState(evt.ChatID, evt.MessageID)
		return
	}

	if retryData.GetResult() != waMmsRetry.MediaRetryNotification_SUCCESS {
		log.Printf("Media retry sem sucesso para %s: chat=%s mensagem=%s resultado=%v", pending.kind, evt.ChatID.String(), evt.MessageID, retryData.GetResult())
		b.clearMediaRetryState(evt.ChatID, evt.MessageID)
		return
	}

	directPath := retryData.GetDirectPath()
	if directPath == "" {
		log.Printf("Media retry sem directPath para %s: chat=%s mensagem=%s", pending.kind, evt.ChatID.String(), evt.MessageID)
		b.clearMediaRetryState(evt.ChatID, evt.MessageID)
		return
	}

	pending.applyDirectPath(directPath)
	b.processMessage(pending.event)
}

func mediaRetryKey(chat types.JID, messageID types.MessageID) string {
	return chat.String() + "|" + string(messageID)
}

func (b *Bridge) clearMediaRetryState(chat types.JID, messageID types.MessageID) {
	key := mediaRetryKey(chat, messageID)
	b.retryMu.Lock()
	delete(b.pendingMediaRetries, key)
	delete(b.mediaRetryAttempts, key)
	b.retryMu.Unlock()
}

func (b *Bridge) hasPendingMediaRetry(chat types.JID, messageID types.MessageID) bool {
	key := mediaRetryKey(chat, messageID)
	b.retryMu.Lock()
	_, ok := b.pendingMediaRetries[key]
	b.retryMu.Unlock()
	return ok
}

func (b *Bridge) takePendingMediaRetry(chat types.JID, messageID types.MessageID) bool {
	key := mediaRetryKey(chat, messageID)
	b.retryMu.Lock()
	_, ok := b.pendingMediaRetries[key]
	delete(b.pendingMediaRetries, key)
	delete(b.mediaRetryAttempts, key)
	b.retryMu.Unlock()
	return ok
}

func shouldRequestMediaRetry(err error) bool {
	return errors.Is(err, whatsmeow.ErrMediaDownloadFailedWith403) ||
		errors.Is(err, whatsmeow.ErrMediaDownloadFailedWith404) ||
		errors.Is(err, whatsmeow.ErrMediaDownloadFailedWith410) ||
		errors.Is(err, context.DeadlineExceeded) ||
		isDNSNotFound(err)
}

func isDNSNotFound(err error) bool {
	var dnsErr *net.DNSError
	if errors.As(err, &dnsErr) {
		return dnsErr.IsNotFound || strings.Contains(strings.ToLower(dnsErr.Err), "no such host")
	}
	return strings.Contains(strings.ToLower(err.Error()), "no such host")
}

func classifyDocumentMedia(rawMime, fileName string) (string, string) {
	mime := normalizeMime(rawMime)
	inferredMime := inferMimeFromFileName(fileName)

	if shouldInferMime(mime) && inferredMime != "" {
		mime = inferredMime
	}

	switch mediaTypeFromMime(mime) {
	case "imagem":
		return "imagem", mime
	case "audio":
		return "audio", mime
	case "video":
		return "video", mime
	default:
		return "documento", mime
	}
}

func normalizeMime(rawMime string) string {
	base, _, _ := strings.Cut(rawMime, ";")
	return strings.TrimSpace(strings.ToLower(base))
}

func shouldInferMime(mime string) bool {
	switch mime {
	case "", "application/octet-stream", "application/ogg", "application/x-ogg":
		return true
	default:
		return false
	}
}

func mediaTypeFromMime(mime string) string {
	switch {
	case strings.HasPrefix(mime, "image/"):
		return "imagem"
	case strings.HasPrefix(mime, "audio/"):
		return "audio"
	case strings.HasPrefix(mime, "video/"):
		return "video"
	default:
		return ""
	}
}

func inferMimeFromFileName(fileName string) string {
	switch strings.ToLower(filepath.Ext(fileName)) {
	case ".jpg", ".jpeg":
		return "image/jpeg"
	case ".png":
		return "image/png"
	case ".gif":
		return "image/gif"
	case ".webp":
		return "image/webp"
	case ".bmp":
		return "image/bmp"
	case ".heic":
		return "image/heic"
	case ".heif":
		return "image/heif"
	case ".mp3":
		return "audio/mpeg"
	case ".m4a":
		return "audio/mp4"
	case ".aac":
		return "audio/aac"
	case ".wav":
		return "audio/wav"
	case ".ogg", ".oga", ".opus":
		return "audio/ogg"
	case ".flac":
		return "audio/flac"
	case ".amr":
		return "audio/amr"
	case ".mp4", ".m4v":
		return "video/mp4"
	case ".mov":
		return "video/quicktime"
	case ".webm":
		return "video/webm"
	case ".mkv":
		return "video/x-matroska"
	case ".avi":
		return "video/x-msvideo"
	default:
		return ""
	}
}

func normalizeStickerMime(rawMime string) string {
	mime := normalizeMime(rawMime)
	if mime == "" {
		return "image/webp"
	}
	return mime
}

func stickerPromptContext(sticker *waProto.StickerMessage) string {
	context := "Esta imagem é uma figurinha/sticker do WhatsApp. Descreva o conteúdo visual e interprete o texto, a expressão, a referência cultural ou o sentido provável da figurinha no contexto de conversa."
	if sticker.GetIsAnimated() {
		context += " A figurinha é animada; examine todos os quadros disponíveis, especialmente textos ou mudanças que aparecem depois dos primeiros quadros."
	}
	if label := strings.TrimSpace(sticker.GetAccessibilityLabel()); label != "" {
		context += " Rótulo de acessibilidade informado pelo WhatsApp: " + label
	}
	return context
}

func stickerThumbnailFallback(sticker *waProto.StickerMessage) ([]byte, string, bool) {
	thumbnail := sticker.GetPngThumbnail()
	if len(thumbnail) == 0 {
		return nil, "", false
	}
	return thumbnail, "image/png", true
}

func (b *Bridge) scheduleStickerMetadataFallback(
	payload IncomingWebhook,
	sticker *waProto.StickerMessage,
	chat types.JID,
	messageID types.MessageID,
) {
	fallback := stickerMetadataFallbackPayload(payload, sticker)
	go func() {
		time.Sleep(12 * time.Second)
		if !b.takePendingMediaRetry(chat, messageID) {
			return
		}
		log.Printf("Media retry de figurinha não respondeu; enfileirando fallback textual: chat=%s mensagem=%s", chat.String(), messageID)
		if err := b.enqueueAndDeliver(fallback); err != nil {
			log.Printf("Erro ao enfileirar fallback textual de figurinha: chat=%s mensagem=%s erro=%v", chat.String(), messageID, err)
		}
	}()
}

func stickerMetadataFallbackPayload(payload IncomingWebhook, sticker *waProto.StickerMessage) IncomingWebhook {
	fallback := payload
	fallback.Tipo = "midia_indisponivel"
	fallback.Mime = ""
	fallback.Dados = ""
	fallback.Caminho = ""
	fallback.Legenda = ""
	fallback.Text = stickerMetadataFallbackText(sticker)
	return fallback
}

func stickerMetadataFallbackText(sticker *waProto.StickerMessage) string {
	parts := []string{
		"A mídia veio indisponível e não pude audiodescrever a figurinha.",
		"Se quiser que eu a descreva, reenvie como imagem, print ou arquivo.",
	}

	if label := strings.TrimSpace(sticker.GetAccessibilityLabel()); label != "" {
		parts = append(parts, "Rótulo de acessibilidade informado pelo WhatsApp: "+label+".")
	}
	if emojis := strings.TrimSpace(sticker.GetEmojis()); emojis != "" {
		parts = append(parts, "Emojis associados ao sticker: "+emojis+".")
	}
	if sticker.GetWidth() > 0 && sticker.GetHeight() > 0 {
		parts = append(parts, fmt.Sprintf("Dimensões declaradas: %dx%d.", sticker.GetWidth(), sticker.GetHeight()))
	}
	if sticker.GetIsAiSticker() {
		parts = append(parts, "O WhatsApp marcou este item como sticker gerado por IA.")
	}
	if sticker.GetIsAnimated() {
		parts = append(parts, "O WhatsApp marcou este item como sticker animado.")
	}

	return strings.Join(parts, "\n")
}

const maxAnimatedStickerFrames = 16
const animatedStickerTileSize = 320

func convertAnimatedStickerToMP4(data []byte) (string, bool) {
	dir, err := os.MkdirTemp("", "amelie_sticker_anim_*")
	if err != nil {
		log.Printf("Falha ao criar diretório temporário para vídeo de figurinha animada: %v", err)
		return "", false
	}
	defer os.RemoveAll(dir)

	inputPath := filepath.Join(dir, "input.webp")
	if err := os.WriteFile(inputPath, data, 0o600); err != nil {
		log.Printf("Falha ao escrever figurinha animada temporária: %v", err)
		return "", false
	}

	scriptPath := filepath.Join(dir, "decode_webp_animation.py")
	if err := os.WriteFile(scriptPath, []byte(animatedWebPToFramesScript), 0o600); err != nil {
		log.Printf("Falha ao escrever decoder de figurinha animada: %v", err)
		return "", false
	}

	framesDir := filepath.Join(dir, "frames")
	out, err := osExec.Command("python3", scriptPath, inputPath, framesDir).CombinedOutput()
	if err != nil {
		log.Printf("Falha ao decodificar ANIM/ANMF da figurinha: erro=%v saida=%s", err, strings.TrimSpace(string(out)))
		return "", false
	}

	mediaDir, err := mediaTempDir()
	if err != nil {
		return "", false
	}
	output, err := os.CreateTemp(mediaDir, mediaTempPrefix+"sticker_*.mp4")
	if err != nil {
		log.Printf("Falha ao criar MP4 temporário de figurinha animada: %v", err)
		return "", false
	}
	outputPath := output.Name()
	output.Close()

	out, err = osExec.Command(
		"ffmpeg",
		"-y",
		"-hide_banner",
		"-loglevel", "error",
		"-f", "concat",
		"-safe", "0",
		"-i", filepath.Join(framesDir, "frames.txt"),
		"-c:v", "libx264",
		"-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2,format=yuv420p",
		"-movflags", "+faststart",
		outputPath,
	).CombinedOutput()
	if err != nil {
		os.Remove(outputPath)
		log.Printf("Falha ao converter figurinha animada para MP4: erro=%v saida=%s", err, strings.TrimSpace(string(out)))
		return "", false
	}

	info, err := os.Stat(outputPath)
	if err != nil || info.Size() == 0 {
		os.Remove(outputPath)
		log.Printf("Conversão de figurinha animada gerou MP4 inválido: erro=%v", err)
		return "", false
	}

	return outputPath, true
}

const animatedWebPToFramesScript = `
import os
import sys
from PIL import Image

def concat_quote(path):
    return "'" + path.replace("'", "'\\''") + "'"

def frame_duration_seconds(image):
    duration_ms = image.info.get("duration") or 100
    try:
        duration_ms = int(duration_ms)
    except Exception:
        duration_ms = 100
    duration_ms = max(20, min(duration_ms, 2000))
    return duration_ms / 1000.0

def main():
    if len(sys.argv) != 3:
        raise SystemExit("uso: decode_webp_animation.py entrada.webp diretorio_frames")

    input_path = sys.argv[1]
    frames_dir = sys.argv[2]
    os.makedirs(frames_dir, exist_ok=True)

    image = Image.open(input_path)
    frame_count = getattr(image, "n_frames", 1)
    if frame_count < 2:
        raise SystemExit("WebP sem animação útil")

    paths = []
    durations = []
    for index in range(frame_count):
        image.seek(index)
        frame = image.convert("RGBA")
        background = Image.new("RGBA", frame.size, (128, 128, 128, 255))
        background.alpha_composite(frame)
        output_path = os.path.join(frames_dir, f"frame_{index:05d}.png")
        background.convert("RGB").save(output_path)
        paths.append(output_path)
        durations.append(frame_duration_seconds(image))

    concat_path = os.path.join(frames_dir, "frames.txt")
    with open(concat_path, "w", encoding="utf-8") as concat:
        concat.write("ffconcat version 1.0\n")
        for path, duration in zip(paths, durations):
            concat.write(f"file {concat_quote(path)}\n")
            concat.write(f"duration {duration:.3f}\n")
        concat.write(f"file {concat_quote(paths[-1])}\n")

    print(f"frames={len(paths)}")

if __name__ == "__main__":
    main()
`

func convertAnimatedStickerToContactSheet(data []byte) ([]byte, string, bool) {
	dir, err := os.MkdirTemp("", "amelie_sticker_frames_*")
	if err != nil {
		log.Printf("Falha ao criar diretório temporário para figurinha animada: %v", err)
		return nil, "", false
	}
	defer os.RemoveAll(dir)

	inputPath := filepath.Join(dir, "input.webp")
	if err := os.WriteFile(inputPath, data, 0o600); err != nil {
		log.Printf("Falha ao escrever figurinha animada temporária: %v", err)
		return nil, "", false
	}

	infoOut, err := osExec.Command("webpmux", "-info", inputPath).CombinedOutput()
	if err != nil {
		log.Printf("Falha ao inspecionar figurinha animada com webpmux: erro=%v saida=%s", err, strings.TrimSpace(string(infoOut)))
		return nil, "", false
	}
	frameCount, ok := parseWebPMuxFrameCount(string(infoOut))
	if !ok || frameCount < 2 {
		log.Printf("Figurinha marcada como animada sem contagem de quadros útil: frames=%d", frameCount)
		return nil, "", false
	}

	indices := sampleFrameIndices(frameCount, maxAnimatedStickerFrames)
	for pos, frameIndex := range indices {
		webpPath := filepath.Join(dir, fmt.Sprintf("frame_%03d.webp", pos+1))
		pngPath := filepath.Join(dir, fmt.Sprintf("frame_%03d.png", pos+1))

		out, err := osExec.Command("webpmux", "-get", "frame", strconv.Itoa(frameIndex), inputPath, "-o", webpPath).CombinedOutput()
		if err != nil {
			log.Printf("Falha ao extrair quadro %d/%d da figurinha: erro=%v saida=%s", frameIndex, frameCount, err, strings.TrimSpace(string(out)))
			return nil, "", false
		}

		out, err = osExec.Command("dwebp", "-quiet", webpPath, "-o", pngPath).CombinedOutput()
		if err != nil {
			log.Printf("Falha ao converter quadro %d da figurinha para PNG: erro=%v saida=%s", frameIndex, err, strings.TrimSpace(string(out)))
			return nil, "", false
		}
	}

	cols, rows := contactSheetGrid(len(indices))
	outputPath := filepath.Join(dir, "sheet.png")
	filter := fmt.Sprintf(
		"scale=%d:%d:force_original_aspect_ratio=decrease,pad=%d:%d:(ow-iw)/2:(oh-ih)/2:color=white,tile=%dx%d:padding=8:margin=8:color=white",
		animatedStickerTileSize,
		animatedStickerTileSize,
		animatedStickerTileSize,
		animatedStickerTileSize,
		cols,
		rows,
	)
	out, err := osExec.Command(
		"ffmpeg",
		"-y",
		"-hide_banner",
		"-loglevel", "error",
		"-framerate", "1",
		"-i", filepath.Join(dir, "frame_%03d.png"),
		"-frames:v", "1",
		"-vf", filter,
		outputPath,
	).CombinedOutput()
	if err != nil {
		log.Printf("Falha ao montar grade de quadros da figurinha: erro=%v saida=%s", err, strings.TrimSpace(string(out)))
		return nil, "", false
	}

	sheet, err := os.ReadFile(outputPath)
	if err != nil || len(sheet) == 0 {
		log.Printf("Grade de quadros da figurinha inválida: erro=%v bytes=%d", err, len(sheet))
		return nil, "", false
	}
	return sheet, "image/png", true
}

func parseWebPMuxFrameCount(info string) (int, bool) {
	for _, line := range strings.Split(info, "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "Number of frames:") {
			value := strings.TrimSpace(strings.TrimPrefix(line, "Number of frames:"))
			count, err := strconv.Atoi(value)
			return count, err == nil
		}
	}
	return 0, false
}

func sampleFrameIndices(frameCount int, maxFrames int) []int {
	if frameCount <= 0 || maxFrames <= 0 {
		return []int{}
	}
	if frameCount <= maxFrames {
		indices := make([]int, frameCount)
		for i := range indices {
			indices[i] = i + 1
		}
		return indices
	}

	indices := make([]int, 0, maxFrames)
	last := 0
	for i := 0; i < maxFrames; i++ {
		index := 1 + (i*(frameCount-1)+(maxFrames-1)/2)/(maxFrames-1)
		if index != last {
			indices = append(indices, index)
			last = index
		}
	}
	return indices
}

func contactSheetGrid(frameCount int) (int, int) {
	if frameCount <= 1 {
		return 1, 1
	}
	cols := 4
	if frameCount < cols {
		cols = frameCount
	}
	rows := (frameCount + cols - 1) / cols
	return cols, rows
}

// mediaTempPrefix identifica arquivos de mídia que o bridge entrega ao Gleam
// por caminho. O Gleam apaga cada arquivo depois de lê-lo; os que sobrarem
// (mensagens abandonadas pela fila) são removidos por cleanupOrphanMediaFiles.
const mediaTempPrefix = "amelie_midia_"

// orphanMediaMaxAge supera a janela de 24h em que a fila ainda tenta entregar.
const orphanMediaMaxAge = 26 * time.Hour

// writeMediaTemp grava a mídia em arquivo temporário. O webhook leva só o
// caminho: base64 de mídia grande ultrapassava o limite de corpo do Mist.
func writeMediaTemp(kind, ext string, data []byte) (string, error) {
	dir, err := mediaTempDir()
	if err != nil {
		return "", err
	}
	f, err := os.CreateTemp(dir, mediaTempPrefix+kind+"_*"+ext)
	if err != nil {
		return "", err
	}
	if _, err := f.Write(data); err != nil {
		f.Close()
		os.Remove(f.Name())
		return "", err
	}
	if err := f.Close(); err != nil {
		os.Remove(f.Name())
		return "", err
	}
	return f.Name(), nil
}

func (b *Bridge) attachMediaFile(payload *IncomingWebhook, kind, ext string, data []byte) bool {
	path, err := writeMediaTemp(kind, ext, data)
	if err != nil {
		log.Printf("Falha ao gravar mídia temporária: chat=%s mensagem=%s tipo=%s mime=%s bytes=%d erro=%v", payload.ChatID, payload.MessageID, kind, payload.Mime, len(data), err)
		return false
	}
	payload.Dados = ""
	payload.Caminho = path
	return true
}

func cleanupOrphanMediaFiles(dir string, maxAge time.Duration) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		log.Printf("[Fila] Erro ao listar mídias temporárias: %v", err)
		return
	}
	limite := time.Now().Add(-maxAge)
	for _, entry := range entries {
		if !entry.Type().IsRegular() || !strings.HasPrefix(entry.Name(), mediaTempPrefix) {
			continue
		}
		info, err := entry.Info()
		if err != nil || info.ModTime().After(limite) {
			continue
		}
		if err := os.Remove(filepath.Join(dir, entry.Name())); err == nil {
			log.Printf("[Fila] Mídia temporária órfã removida: %s", entry.Name())
		}
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

// ---------------------------------------------------------------------------
// Fila persistente de webhook
// ---------------------------------------------------------------------------

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

	// Limpar entregas antigas na inicialização
	db.Exec(`DELETE FROM webhook_queue WHERE delivered_at IS NOT NULL AND created_at < unixepoch() - 3600`)
	db.Exec(`DELETE FROM webhook_queue WHERE attempts >= 100 AND created_at < unixepoch() - 86400`)

	b.queueDB = db
	return nil
}

func (b *Bridge) enqueueAndDeliver(payload IncomingWebhook) error {
	data, err := json.Marshal(payload)
	if err != nil {
		return err
	}

	// Deduplicar: se já existe na fila (entregue ou não), ignorar.
	if payload.MessageID != "" {
		var count int
		b.queueDB.QueryRow("SELECT COUNT(*) FROM webhook_queue WHERE message_id = ?", payload.MessageID).Scan(&count)
		if count > 0 {
			return nil
		}
	}

	result, err := b.queueDB.Exec(
		"INSERT INTO webhook_queue (message_id, payload) VALUES (?, ?)",
		payload.MessageID, string(data),
	)
	if err != nil {
		return fmt.Errorf("fila: erro ao enfileirar: %w", err)
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

func (b *Bridge) processQueue() {
	rows, err := b.queueDB.Query(
		`SELECT id, payload FROM webhook_queue
		 WHERE delivered_at IS NULL AND attempts < 100
		 AND created_at > unixepoch() - 86400
		 ORDER BY id ASC LIMIT 50`,
	)
	if err != nil {
		log.Printf("[Fila] Erro ao consultar pendentes: %v", err)
		return
	}
	defer rows.Close()

	for rows.Next() {
		var id int64
		var payloadJSON string
		if err := rows.Scan(&id, &payloadJSON); err != nil {
			continue
		}

		var payload IncomingWebhook
		if err := json.Unmarshal([]byte(payloadJSON), &payload); err != nil {
			log.Printf("[Fila] Payload corrompido id=%d, descartando: %v", id, err)
			b.queueDB.Exec("UPDATE webhook_queue SET delivered_at = -1 WHERE id = ?", id)
			continue
		}

		b.queueDB.Exec("UPDATE webhook_queue SET attempts = attempts + 1 WHERE id = ?", id)

		if err := b.postToGleam(payload); err != nil {
			log.Printf("[Fila] Retry falhou id=%d: %v", id, err)
			return // Gleam indisponível, parar e tentar tudo de novo no próximo tick
		}

		b.queueDB.Exec("UPDATE webhook_queue SET delivered_at = unixepoch() WHERE id = ?", id)
		log.Printf("[Fila] Mensagem %d entregue com sucesso (msg_id=%s)", id, payload.MessageID)
	}
}

func (b *Bridge) cleanupQueue() {
	b.queueDB.Exec(`DELETE FROM webhook_queue WHERE delivered_at IS NOT NULL AND created_at < unixepoch() - 3600`)
	b.queueDB.Exec(`DELETE FROM webhook_queue WHERE attempts >= 100 AND created_at < unixepoch() - 86400`)
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
		return fmt.Errorf("gleam retornou status %d: %s", resp.StatusCode, string(body))
	}
	return nil
}

// ---------------------------------------------------------------------------
// Envio de mensagens (HTTP handler)
// ---------------------------------------------------------------------------

func (b *Bridge) handleSend(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeAPIError(w, http.StatusMethodNotAllowed, APIError{
			Code:    "method_not_allowed",
			Message: "use POST em /send",
		})
		return
	}

	var req SendRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeAPIError(w, http.StatusBadRequest, APIError{
			Code:    "invalid_json",
			Message: fmt.Sprintf("corpo JSON inválido: %v", err),
		})
		return
	}

	jid, err := types.ParseJID(req.ChatID)
	if err != nil {
		writeAPIError(w, http.StatusBadRequest, APIError{
			Code:    "invalid_chat_id",
			Message: fmt.Sprintf("chat_id %q inválido: %v", req.ChatID, err),
		})
		return
	}
	if availabilityError := b.availabilityError(); availabilityError != nil {
		writeAPIError(w, http.StatusServiceUnavailable, *availabilityError)
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

	_, err = b.sendMessageWithRetry(jid, msg)
	if err != nil {
		log.Printf("Erro ao enviar mensagem: %v\n", err)
		b.writeWhatsAppOperationError(w, "send", "falha ao enviar mensagem", err)
		return
	}

	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

func (b *Bridge) sendMessageWithRetry(jid types.JID, msg *waProto.Message) (any, error) {
	var lastErr error
	for attempt := 0; attempt < 5; attempt++ {
		if attempt > 0 {
			time.Sleep(time.Duration(attempt*100) * time.Millisecond)
		}
		result, err := b.client.SendMessage(context.Background(), jid, msg)
		if err == nil {
			return result, nil
		}
		// Retry only on SQLITE_BUSY (code 5)
		if !strings.Contains(err.Error(), "database is locked") &&
			!strings.Contains(err.Error(), "SQLITE_BUSY") {
			return nil, err
		}
		lastErr = err
		log.Printf("[SendRetry] attempt %d: %v", attempt+1, err)
	}
	return nil, lastErr
}

func (b *Bridge) handleReact(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeAPIError(w, http.StatusMethodNotAllowed, APIError{
			Code:    "method_not_allowed",
			Message: "use POST em /react",
		})
		return
	}

	var req ReactRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeAPIError(w, http.StatusBadRequest, APIError{
			Code:    "invalid_json",
			Message: fmt.Sprintf("corpo JSON inválido: %v", err),
		})
		return
	}

	chatJID, err := types.ParseJID(req.ChatID)
	if err != nil {
		writeAPIError(w, http.StatusBadRequest, APIError{
			Code:    "invalid_chat_id",
			Message: fmt.Sprintf("chat_id %q inválido: %v", req.ChatID, err),
		})
		return
	}
	if availabilityError := b.availabilityError(); availabilityError != nil {
		writeAPIError(w, http.StatusServiceUnavailable, *availabilityError)
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

	_, err = b.sendMessageWithRetry(chatJID, msg)
	if err != nil {
		log.Printf("Erro ao enviar reação: %v\n", err)
		b.writeWhatsAppOperationError(w, "react", "falha ao enviar reação", err)
		return
	}

	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

func (b *Bridge) writeWhatsAppOperationError(
	w http.ResponseWriter,
	operationCode string,
	operationMessage string,
	err error,
) {
	if availabilityError := b.availabilityError(); availabilityError != nil {
		writeAPIError(w, http.StatusServiceUnavailable, *availabilityError)
		return
	}
	writeAPIError(w, http.StatusBadGateway, APIError{
		Code:    "whatsapp_" + operationCode + "_failed",
		Message: fmt.Sprintf("%s: %v", operationMessage, err),
	})
}

func (b *Bridge) handleHealth(w http.ResponseWriter, _ *http.Request) {
	if availabilityError := b.availabilityError(); availabilityError != nil {
		writeJSON(w, http.StatusServiceUnavailable, HealthResponse{
			Status:   "unavailable",
			LoggedIn: false,
			APIError: availabilityError,
		})
		return
	}
	writeJSON(w, http.StatusOK, HealthResponse{
		Status:   "ok",
		LoggedIn: true,
	})
}

type PairPhoneRequest struct {
	Phone string `json:"phone"`
}

type PairPhoneResponse struct {
	OK    bool   `json:"ok"`
	Code  string `json:"code,omitempty"`
	Phone string `json:"phone,omitempty"`
	Error string `json:"error,omitempty"`
}

func (b *Bridge) handlePairPhone(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, ErrorResponse{
			OK: false,
			APIError: APIError{
				Code:    "method_not_allowed",
				Message: "método não permitido; use POST",
			},
		})
		return
	}

	phone := ""
	if r.Method == http.MethodPost && r.Body != nil {
		var req PairPhoneRequest
		_ = json.NewDecoder(r.Body).Decode(&req)
		phone = req.Phone
	}
	if phone == "" {
		phone = r.URL.Query().Get("phone")
	}
	if phone == "" {
		phone = b.cfg.BotPhone
	}

	phone = cleanPhoneNumber(phone)
	if phone == "" {
		writeJSON(w, http.StatusBadRequest, PairPhoneResponse{
			OK:    false,
			Error: "número de telefone não informado (defina 'phone' ou MOBILE_NUMBER)",
		})
		return
	}

	if b.client != nil && b.client.IsConnected() && b.client.IsLoggedIn() {
		writeJSON(w, http.StatusConflict, PairPhoneResponse{
			OK:    false,
			Error: "WhatsApp já está conectado e autenticado nesta sessão",
		})
		return
	}

	code, err := b.requestPairingCode(phone)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, PairPhoneResponse{
			OK:    false,
			Error: fmt.Sprintf("falha ao gerar pairing code: %v", err),
		})
		return
	}

	writeJSON(w, http.StatusOK, PairPhoneResponse{
		OK:    true,
		Code:  code,
		Phone: phone,
	})
}

type ResetSessionRequest struct {
	Phone string `json:"phone,omitempty"`
}

type ResetSessionResponse struct {
	OK     bool   `json:"ok"`
	Status string `json:"status"`
	Error  string `json:"error,omitempty"`
}

func (b *Bridge) handleResetSession(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, ErrorResponse{
			OK: false,
			APIError: APIError{
				Code:    "method_not_allowed",
				Message: "método não permitido; use POST",
			},
		})
		return
	}

	phone := ""
	if r.Body != nil {
		var req ResetSessionRequest
		_ = json.NewDecoder(r.Body).Decode(&req)
		phone = req.Phone
	}
	if phone == "" {
		phone = r.URL.Query().Get("phone")
	}
	if phone == "" {
		phone = b.cfg.BotPhone
	}
	if phone == "" && b.client != nil && b.client.Store != nil && b.client.Store.ID != nil {
		phone = b.client.Store.ID.User
	}
	phone = cleanPhoneNumber(phone)

	log.Printf("[WhatsApp] Reset de sessão solicitado. Desconectando e limpando dados...")
	if b.client != nil && b.client.IsConnected() {
		b.client.Disconnect()
	}
	b.setConnectionError("session_reset", "sessão reiniciada manualmente pelo administrador")
	b.deleteSessionStore()

	if phone != "" {
		go func(targetPhone string) {
			time.Sleep(2 * time.Second)
			log.Printf("[WhatsApp] Gerando novo pairing code pós-reset para %s...\n", targetPhone)
			code, err := b.requestPairingCode(targetPhone)
			if err != nil {
				log.Printf("[WhatsApp] Erro ao gerar pairing code pós-reset: %v\n", err)
				b.notifyGleamEvent(map[string]interface{}{
					"evento": "whatsapp_down",
					"motivo": fmt.Sprintf("Reset executado. Falha ao gerar pairing code: %v", err),
				})
			} else {
				log.Printf("[WhatsApp] Novo pairing code pós-reset gerado com sucesso: %s\n", code)
			}
		}(phone)
	}

	writeJSON(w, http.StatusOK, ResetSessionResponse{
		OK:     true,
		Status: "session_reset_initiated",
	})
}

func (b *Bridge) deleteSessionStore() {
	if b.client != nil {
		if b.client.IsConnected() {
			b.client.Disconnect()
		}
		if b.client.Store != nil && b.client.Store.Container != nil {
			_ = b.client.Store.Delete(context.Background())
		}
	}
	if b.container != nil {
		newDevice := b.container.NewDevice()
		b.client = whatsmeow.NewClient(newDevice, b.clientLog)
		b.client.AddEventHandler(b.handleEvent)
	} else if b.client != nil && b.client.Store != nil {
		b.client.Store.ID = nil
	}
}

func (b *Bridge) requestPairingCode(phone string) (string, error) {
	if b.client.Store.ID != nil && !b.client.IsLoggedIn() {
		b.deleteSessionStore()
	}

	qrChan, _ := b.client.GetQRChannel(context.Background())
	if !b.client.IsConnected() {
		if err := b.client.Connect(); err != nil {
			return "", fmt.Errorf("conectar websocket: %w", err)
		}
	}

	select {
	case evt, ok := <-qrChan:
		if !ok {
			return "", fmt.Errorf("canal de autenticação fechou antes do pareamento")
		}
		if evt.Event == "success" {
			return "", fmt.Errorf("já autenticado")
		}
	case <-time.After(5 * time.Second):
	}

	code, err := b.client.PairPhone(context.Background(), phone, true, whatsmeow.PairClientChrome, "Chrome (Linux)")
	if err != nil {
		return "", err
	}

	b.notifyGleamEvent(map[string]interface{}{
		"evento": "pairing_code",
		"phone":  phone,
		"code":   code,
	})

	log.Println("==================================================")
	log.Printf("📱 PAIRING CODE GERADO PARA %s: %s\n", phone, code)
	log.Println("👉 No WhatsApp do celular:")
	log.Println("   Aparelhos conectados > Conectar com número de telefone")
	log.Printf("   e digite o código: %s\n", code)
	log.Println("==================================================")

	go func() {
		for evt := range qrChan {
			switch evt.Event {
			case "success":
				log.Printf("[WhatsApp] Autenticação via Pairing Code realizada com sucesso!")
				return
			case "timeout":
				log.Printf("[WhatsApp] Pairing code expirou sem ser confirmado.")
				return
			default:
				log.Printf("[WhatsApp] Evento de autenticação: %s\n", evt.Event)
			}
		}
	}()

	return code, nil
}

func (b *Bridge) notifyGleamEvent(payload map[string]interface{}) {
	if b.cfg.GleamURL == "" {
		return
	}
	data, err := json.Marshal(payload)
	if err != nil {
		log.Printf("[Bridge] Erro ao codificar evento para o Gleam: %v\n", err)
		return
	}
	eventURL := strings.Replace(b.cfg.GleamURL, "/webhook", "/webhook/bridge-event", 1)

	go func() {
		for attempt := 1; attempt <= 5; attempt++ {
			resp, err := b.postAuthenticated(eventURL, data)
			if err == nil {
				_ = resp.Body.Close()
				if resp.StatusCode >= 200 && resp.StatusCode < 300 {
					log.Printf("[Bridge] Evento '%v' notificado ao Gleam com sucesso\n", payload["evento"])
					return
				}
				err = fmt.Errorf("Gleam retornou status %d", resp.StatusCode)
			}
			log.Printf("[Bridge] Falha ao notificar evento ao Gleam (tentativa %d/5): %v\n", attempt, err)
			time.Sleep(1 * time.Second)
		}
	}()
}

func writeAPIError(w http.ResponseWriter, status int, apiError APIError) {
	if apiError.Timestamp == "" {
		apiError.Timestamp = time.Now().Format(time.RFC3339)
	}
	writeJSON(w, status, ErrorResponse{OK: false, APIError: apiError})
}

func writeJSON(w http.ResponseWriter, status int, payload any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(payload); err != nil {
		log.Printf("Erro ao escrever resposta JSON HTTP: %v", err)
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
