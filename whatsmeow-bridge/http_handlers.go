package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"strings"
	"time"

	waProto "go.mau.fi/whatsmeow/binary/proto"
	"go.mau.fi/whatsmeow/types"
	"google.golang.org/protobuf/proto"
)

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
		result, err := b.wa().SendMessage(context.Background(), jid, msg)
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

	if c := b.wa(); c != nil && c.IsConnected() && c.IsLoggedIn() {
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

	log.Printf("[WhatsApp] Reset de sessão solicitado. Desconectando e limpando dados...")
	// Sob pairingMu: um pareamento em andamento usa o cliente atual do começo
	// ao fim, e o reset não pode trocá-lo no meio. Mesma ordem de locks de
	// pairLocked (pairingMu, depois resetMu em deleteSessionStore). O
	// telefone da sessão também é lido aqui dentro, já com o estado final de
	// um pareamento que terminou antes.
	b.pairingMu.Lock()
	if c := b.wa(); phone == "" && c != nil && c.Store != nil && c.Store.ID != nil {
		phone = c.Store.ID.User
	}
	phone = cleanPhoneNumber(phone)
	if c := b.wa(); c != nil && c.IsConnected() {
		c.Disconnect()
	}
	b.setConnectionError("session_reset", "sessão reiniciada manualmente pelo administrador")
	b.deleteSessionStore()
	b.pairingMu.Unlock()

	if phone != "" {
		// Lido aqui, não na goroutine: os testes trocam o valor entre rodadas.
		delay := resetPairingDelay
		go func(targetPhone string) {
			time.Sleep(delay)
			log.Printf("[WhatsApp] Gerando novo pairing code pós-reset para %s...\n", maskID(targetPhone))
			_, err := b.requestPairingCode(targetPhone)
			if err != nil {
				log.Printf("[WhatsApp] Erro ao gerar pairing code pós-reset: %v\n", err)
				b.notifyGleamEvent(map[string]interface{}{
					"evento": "whatsapp_down",
					"motivo": fmt.Sprintf("Reset executado. Falha ao gerar pairing code: %v", err),
				})
			} else {
				log.Printf("[WhatsApp] Novo pairing code pós-reset gerado para %s\n", maskID(targetPhone))
			}
		}(phone)
	}

	writeJSON(w, http.StatusOK, ResetSessionResponse{
		OK:     true,
		Status: "session_reset_initiated",
	})
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
