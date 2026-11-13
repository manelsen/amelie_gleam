package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net"
	"os"
	"path/filepath"
	"strings"
	"time"

	"go.mau.fi/whatsmeow"
	waProto "go.mau.fi/whatsmeow/binary/proto"
	waMmsRetry "go.mau.fi/whatsmeow/proto/waMmsRetry"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
)

type mediaRetryPending struct {
	event           *events.Message
	kind            string
	mediaKey        []byte
	applyDirectPath func(string)
}

func (b *Bridge) downloadMediaBytes(
	evt *events.Message,
	kind string,
	mime string,
	fileName string,
	msg whatsmeow.DownloadableMessage,
	applyDirectPath func(string),
) ([]byte, bool) {
	// O tamanho declarado pode mentir; o limitedFile é que limita de fato.
	if declaredMediaTooLarge(msg) {
		log.Printf("%s recusado antes do download: tamanho declarado acima de 50 MiB", kind)
		return nil, false
	}
	type resultado struct {
		data []byte
		err  error
	}
	r := withMediaDownloadSlot(func() resultado {
		// Fail fast para domínios fantasmas do WhatsApp que causam delays de 15s
		ctx, cancel := context.WithTimeout(context.Background(), mediaDownloadTimeout(kind, declaredMediaBytes(msg)))
		defer cancel()
		data, err := downloadIntoLimitedFile(func(f *limitedFile) error {
			return b.wa().DownloadToFile(ctx, msg, f)
		})
		return resultado{data, err}
	})
	data, err := r.data, r.err
	if errors.Is(err, errMediaTooLarge) {
		log.Printf("%s descartado: download passou de 50 MiB", kind)
		return nil, false
	}
	if err == nil {
		if len(data) == 0 {
			log.Printf("%s vazio recebido do WhatsApp: chat=%s mime=%s arquivo=%q", kind, maskID(evt.Info.Chat.String()), mime, fileName)
			return nil, false
		}
		return data, true
	}

	if shouldRequestMediaRetry(err) {
		if retryErr := b.requestMediaRetry(evt, kind, msg.GetMediaKey(), applyDirectPath); retryErr != nil {
			log.Printf("Falha ao solicitar media retry para %s: chat=%s mime=%s arquivo=%q erro_download=%v erro_retry=%v", kind, maskID(evt.Info.Chat.String()), mime, fileName, err, retryErr)
			b.clearMediaRetryState(evt.Info.Chat, evt.Info.ID)
		} else {
			log.Printf("Media retry solicitado para %s: chat=%s mime=%s arquivo=%q erro_download=%v", kind, maskID(evt.Info.Chat.String()), mime, fileName, err)
		}
		return nil, false
	}

	// Se for erro de conexão ou timeout curto, não insiste 15s
	if strings.Contains(err.Error(), "connection refused") || strings.Contains(err.Error(), "context deadline exceeded") {
		log.Printf("Download de %s abortado rapidamente: chat=%s mime=%s arquivo=%q erro=%v", kind, maskID(evt.Info.Chat.String()), mime, fileName, err)
		return nil, false
	}

	log.Printf("Falha ao baixar %s do WhatsApp: chat=%s mime=%s arquivo=%q erro=%v", kind, maskID(evt.Info.Chat.String()), mime, fileName, err)
	return nil, false
}

func (b *Bridge) downloadStickerBytes(
	evt *events.Message,
	mime string,
	sticker *waProto.StickerMessage,
	applyDirectPath func(string),
) ([]byte, bool) {
	if sticker.GetDirectPath() != "" {
		if declaredMediaTooLarge(sticker) {
			log.Printf("figurinha recusada antes do download: tamanho declarado acima de 50 MiB")
			return nil, false
		}
		type resultado struct {
			data []byte
			err  error
		}
		r := withMediaDownloadSlot(func() resultado {
			ctx, cancel := context.WithTimeout(context.Background(), mediaDownloadTimeout("figurinha", sticker.GetFileLength()))
			defer cancel()
			data, err := downloadIntoLimitedFile(func(f *limitedFile) error {
				return b.wa().DownloadMediaWithPathToFile(
					ctx,
					sticker.GetDirectPath(),
					sticker.GetFileEncSHA256(),
					sticker.GetFileSHA256(),
					sticker.GetMediaKey(),
					whatsmeow.MediaImage,
					"sticker",
					false,
					f,
				)
			})
			return resultado{data, err}
		})
		data, err := r.data, r.err
		if errors.Is(err, errMediaTooLarge) {
			log.Printf("figurinha descartada: download passou de 50 MiB")
			return nil, false
		}
		if err == nil {
			if len(data) == 0 {
				log.Printf("figurinha vazia recebida do WhatsApp com mms-type=sticker: chat=%s mime=%s", maskID(evt.Info.Chat.String()), mime)
				return nil, false
			}
			log.Printf("Figurinha baixada com mms-type=sticker: chat=%s mensagem=%s bytes=%d", maskID(evt.Info.Chat.String()), evt.Info.ID, len(data))
			return data, true
		}
		log.Printf("Falha ao baixar figurinha com mms-type=sticker: chat=%s mensagem=%s mime=%s erro=%v", maskID(evt.Info.Chat.String()), evt.Info.ID, mime, err)
	}

	return b.downloadMediaBytes(evt, "figurinha", mime, "", sticker, applyDirectPath)
}

func mediaDownloadTimeout(kind string, declaredBytes uint64) time.Duration {
	d := mediaTimeoutBase + time.Duration(declaredBytes/(1<<20))*mediaTimeoutPorMiB
	if kind == "figurinha" && d < stickerTimeoutMin {
		d = stickerTimeoutMin
	}
	if d > mediaTimeoutMax {
		d = mediaTimeoutMax
	}
	return d
}

func declaredMediaBytes(msg any) uint64 {
	if sized, ok := msg.(sizedMedia); ok {
		return sized.GetFileLength()
	}
	return 0
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

	if err := b.wa().SendMediaRetryReceipt(context.Background(), &evt.Info, mediaKey); err != nil {
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
		log.Printf("Media retry recebido sem contexto local: chat=%s mensagem=%s", maskID(evt.ChatID.String()), evt.MessageID)
		return
	}

	retryData, err := whatsmeow.DecryptMediaRetryNotification(evt, pending.mediaKey)
	if err != nil {
		log.Printf("Falha ao descriptografar media retry de %s: chat=%s mensagem=%s erro=%v", pending.kind, maskID(evt.ChatID.String()), evt.MessageID, err)
		b.clearMediaRetryState(evt.ChatID, evt.MessageID)
		return
	}

	if retryData.GetResult() != waMmsRetry.MediaRetryNotification_SUCCESS {
		log.Printf("Media retry sem sucesso para %s: chat=%s mensagem=%s resultado=%v", pending.kind, maskID(evt.ChatID.String()), evt.MessageID, retryData.GetResult())
		b.clearMediaRetryState(evt.ChatID, evt.MessageID)
		return
	}

	directPath := retryData.GetDirectPath()
	if directPath == "" {
		log.Printf("Media retry sem directPath para %s: chat=%s mensagem=%s", pending.kind, maskID(evt.ChatID.String()), evt.MessageID)
		b.clearMediaRetryState(evt.ChatID, evt.MessageID)
		return
	}

	pending.applyDirectPath(directPath)
	b.dispatchMessage(pending.event)
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
		log.Printf("Falha ao gravar mídia temporária: chat=%s mensagem=%s tipo=%s mime=%s bytes=%d erro=%v", maskID(payload.ChatID), payload.MessageID, kind, payload.Mime, len(data), err)
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
		name := entry.Name()
		if !entry.Type().IsRegular() || (!strings.HasPrefix(name, mediaTempPrefix) && !strings.HasPrefix(name, "amelie_local_")) {
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

// Prazo do download inteiro. Curto o bastante para desistir logo de um host
// de mídia que não responde (o pedido de reenvio traz outro caminho), mas
// proporcional ao tamanho declarado: com 2 s fixos, vídeos e PDFs grandes
// nunca terminavam e eram descartados.
const (
	mediaTimeoutBase   = 5 * time.Second
	mediaTimeoutPorMiB = 1 * time.Second
	mediaTimeoutMax    = 2 * time.Minute
	stickerTimeoutMin  = 8 * time.Second
)
