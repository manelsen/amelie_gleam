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
	GleamURL string // URL do webhook Gleam (default: http://localhost:4000/webhook)
	DBPath   string // SQLite para sessão WhatsApp (default: ./db/whatsmeow.db)
	BotPhone string // Número para Pairing Code (opcional, ativa Pairing Code se definido)
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
	cfg                 Config
	client              *whatsmeow.Client
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

	clientLog := waLog.Stdout("Client", "WARN", true)
	client := whatsmeow.NewClient(deviceStore, clientLog)

	b := &Bridge{
		cfg:                 cfg,
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
			if evt.Event == "timeout" {
				return fmt.Errorf("QR code expirou sem ser escaneado — reiniciando para gerar novo")
			}
		}
	}
	return nil
}

func (b *Bridge) loginPairingCode() error {
	if err := b.client.Connect(); err != nil {
		return err
	}
	code, err := b.client.PairPhone(context.Background(), b.cfg.BotPhone, true, whatsmeow.PairClientChrome, "Chrome (Linux)")
	if err != nil {
		return fmt.Errorf("pairing code: %w", err)
	}
	log.Printf("Pairing Code: %s\n", code)
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
	case *events.HistorySync:
		b.processHistorySync(evt)
	case *events.MediaRetry:
		b.handleMediaRetry(evt)
	}
}

func (b *Bridge) processHistorySync(evt *events.HistorySync) {
	// Só encaminhar mensagens das últimas 48h — o history sync do WhatsApp
	// reenvia o histórico completo ao reconectar, o que faria o bot responder
	// mensagens já respondidas antes de um reinício ou recriação do banco.
	cutoff := time.Now().Add(-48 * time.Hour)

	data := evt.Data
	convs := data.GetConversations()
	for _, conv := range convs {
		chatID := conv.GetID()
		chatJID, err := types.ParseJID(chatID)
		if err != nil {
			log.Printf("[HistorySync] JID inválido %s: %v", chatID, err)
			continue
		}

		msgs := conv.GetMessages()
		for _, syncMsg := range msgs {
			webMsg := syncMsg.GetMessage()
			if webMsg == nil {
				continue
			}
			msgID := webMsg.GetKey().GetID()
			parsed, err := b.client.ParseWebMessage(chatJID, webMsg)
			if err != nil {
				log.Printf("[HistorySync] Erro ao parsear mensagem %s: %v", msgID, err)
				continue
			}
			if parsed.Info.Timestamp.Before(cutoff) {
				continue
			}
			b.processMessage(parsed)
		}
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
		data, ok := b.downloadMediaBytes(evt, "imagem", payload.Mime, "", img, func(path string) {
			img.URL = nil
			img.DirectPath = proto.String(path)
		})
		if !ok {
			return
		}
		payload.Dados = base64.StdEncoding.EncodeToString(data)
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
		payload.Dados = base64.StdEncoding.EncodeToString(data)
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
			payload.Dados = base64.StdEncoding.EncodeToString(data)
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
			payload.Dados = base64.StdEncoding.EncodeToString(data)
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
			tmpFile, ferr := os.CreateTemp("", "amelie_video_*.mp4")
			if ferr != nil {
				log.Printf("Falha ao criar arquivo temporario de video: chat=%s mime=%s arquivo=%q erro=%v", chatID, mime, fileName, ferr)
				return
			}
			_, _ = tmpFile.Write(data)
			payload.Caminho = tmpFile.Name()
			tmpFile.Close()
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
			payload.Dados = base64.StdEncoding.EncodeToString(data)
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
		tmpFile, err := os.CreateTemp("", "amelie_video_*.mp4")
		if err != nil {
			log.Printf("Falha ao criar arquivo temporario de video: chat=%s mime=%s erro=%v", chatID, payload.Mime, err)
			return
		}
		tmpFile.Write(data)
		payload.Caminho = tmpFile.Name()
		tmpFile.Close()
	} else if sticker := evt.Message.GetStickerMessage(); sticker != nil {
		payload.Tipo = "imagem"
		payload.Mime = normalizeStickerMime(sticker.GetMimetype())
		payload.Legenda = stickerPromptContext(sticker)
		data, ok := b.downloadMediaBytes(evt, "figurinha", payload.Mime, "", sticker, func(path string) {
			sticker.URL = nil
			sticker.DirectPath = proto.String(path)
		})
		if !ok {
			var fallbackOK bool
			data, payload.Mime, fallbackOK = stickerThumbnailFallback(sticker)
			if !fallbackOK {
				return
			}
			log.Printf("Usando thumbnail PNG da figurinha como fallback: chat=%s mensagem=%s", chatID, evt.Info.ID)
		}
		if sticker.GetIsAnimated() && ok {
			videoPath, convOK := convertAnimatedStickerToMP4(data)
			if convOK {
				payload.Tipo = "video"
				payload.Mime = "video/mp4"
				payload.Caminho = videoPath
			} else {
				payload.Dados = base64.StdEncoding.EncodeToString(data)
			}
		} else {
			payload.Dados = base64.StdEncoding.EncodeToString(data)
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
	data, err := b.client.Download(context.Background(), msg)
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
		}
		return nil, false
	}

	log.Printf("Falha ao baixar %s do WhatsApp: chat=%s mime=%s arquivo=%q erro=%v", kind, evt.Info.Chat.String(), mime, fileName, err)
	return nil, false
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

func shouldRequestMediaRetry(err error) bool {
	return errors.Is(err, whatsmeow.ErrMediaDownloadFailedWith403) ||
		errors.Is(err, whatsmeow.ErrMediaDownloadFailedWith404) ||
		errors.Is(err, whatsmeow.ErrMediaDownloadFailedWith410) ||
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
		context += " A figurinha é animada; se a mídia recebida mostrar apenas um quadro, descreva o que estiver visível nesse quadro."
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

func convertAnimatedStickerToMP4(data []byte) (string, bool) {
	input, err := os.CreateTemp("", "amelie_sticker_*.webp")
	if err != nil {
		log.Printf("Falha ao criar arquivo temporario de figurinha animada: %v", err)
		return "", false
	}
	inputPath := input.Name()
	defer os.Remove(inputPath)

	if _, err := input.Write(data); err != nil {
		input.Close()
		log.Printf("Falha ao escrever figurinha animada temporaria: %v", err)
		return "", false
	}
	if err := input.Close(); err != nil {
		log.Printf("Falha ao fechar figurinha animada temporaria: %v", err)
		return "", false
	}

	output, err := os.CreateTemp("", "amelie_sticker_*.mp4")
	if err != nil {
		log.Printf("Falha ao criar video temporario de figurinha animada: %v", err)
		return "", false
	}
	outputPath := output.Name()
	output.Close()

	cmd := osExec.Command(
		"ffmpeg",
		"-y",
		"-i", inputPath,
		"-movflags", "+faststart",
		"-pix_fmt", "yuv420p",
		"-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2",
		outputPath,
	)
	out, err := cmd.CombinedOutput()
	if err != nil {
		os.Remove(outputPath)
		log.Printf("Falha ao converter figurinha animada para MP4: erro=%v saida=%s", err, strings.TrimSpace(string(out)))
		return "", false
	}

	info, err := os.Stat(outputPath)
	if err != nil || info.Size() == 0 {
		os.Remove(outputPath)
		log.Printf("Conversao de figurinha animada gerou arquivo invalido: erro=%v", err)
		return "", false
	}

	return outputPath, true
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
	body, _ := io.ReadAll(resp.Body)
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

	_, err = b.sendMessageWithRetry(jid, msg)
	if err != nil {
		log.Printf("Erro ao enviar mensagem: %v\n", err)
		http.Error(w, "send failed", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.Write([]byte(`{"ok":true}`))
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

	_, err = b.sendMessageWithRetry(chatJID, msg)
	if err != nil {
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
