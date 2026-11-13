package main

import (
	"context"
	"log"

	waProto "go.mau.fi/whatsmeow/binary/proto"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
	"google.golang.org/protobuf/proto"
)

// dispatchMessage tira o processamento da mensagem do handler de eventos.
// Ver chatDispatcher.
func (b *Bridge) dispatchMessage(evt *events.Message) {
	chat := evt.Info.Chat.String()
	if !b.dispatch.submit(chat, string(evt.Info.ID), func() { b.processMessage(evt) }) {
		log.Printf("[Despacho] Fila do chat %s cheia; mensagem %s descartada", maskID(chat), evt.Info.ID)
	}
}

func (b *Bridge) processMessage(evt *events.Message) {
	if evt.Info.IsFromMe {
		return
	}

	// Só conversas privadas. Decidido antes de qualquer download de mídia.
	switch chatPolicyFor(evt.Info.Chat.Server) {
	case chatLeave:
		b.leaveGroup(evt.Info.Chat)
		return
	case chatDrop:
		return
	}

	chatID := evt.Info.Chat.String()
	from := evt.Info.Sender.String()
	inGroup := evt.Info.IsGroup
	timestamp := evt.Info.Timestamp.Unix()

	// Se o remetente for um LID (identificador mascarado), tenta resolver o número real via LIDStore do whatsmeow
	if c := b.wa(); c != nil && c.Store != nil && c.Store.LIDs != nil {
		if evt.Info.Sender.Server == types.HiddenUserServer {
			if pn, err := c.Store.LIDs.GetPNForLID(context.Background(), evt.Info.Sender.ToNonAD()); err == nil && !pn.IsEmpty() {
				from = pn.String()
			}
		}
		if !inGroup && evt.Info.Chat.Server == types.HiddenUserServer {
			if pn, err := c.Store.LIDs.GetPNForLID(context.Background(), evt.Info.Chat.ToNonAD()); err == nil && !pn.IsEmpty() {
				chatID = pn.String()
			}
		}
	}

	payload := IncomingWebhook{
		ChatID:    chatID,
		From:      from,
		MessageID: evt.Info.ID,
		Timestamp: timestamp,
		InGroup:   inGroup,
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
		log.Printf("Figurinha recebida: chat=%s mensagem=%s mime=%s animada=%v", maskID(chatID), evt.Info.ID, payload.Mime, sticker.GetIsAnimated())
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
				log.Printf("Usando thumbnail PNG da figurinha como fallback: chat=%s mensagem=%s", maskID(chatID), evt.Info.ID)
			} else {
				log.Printf("Figurinha sem dados e sem thumbnail: chat=%s mensagem=%s mime=%s animada=%v", maskID(chatID), evt.Info.ID, payload.Mime, sticker.GetIsAnimated())
				if err := b.enqueueAndDeliver(stickerMetadataFallbackPayload(payload, sticker)); err != nil {
					log.Printf("Erro ao enfileirar fallback textual de figurinha: chat=%s mensagem=%s erro=%v", maskID(chatID), evt.Info.ID, err)
				}
				return
			}
		}
		if sticker.GetIsAnimated() {
			// A conversão chama processos externos sobre conteúdo de terceiros.
			// Fora do handler, para não segurar as mensagens dos outros usuários.
			if tryAcquireStickerSlot() {
				go b.deliverAnimatedSticker(payload, data, evt.Info.Chat, evt.Info.ID)
				return
			}
			log.Printf("Limite de conversões simultâneas atingido; figurinha animada segue como WebP estático: chat=%s mensagem=%s", maskID(chatID), evt.Info.ID)
		}
		if !b.attachMediaFile(&payload, "sticker", "", data) {
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
