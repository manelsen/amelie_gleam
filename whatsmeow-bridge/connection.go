package main

import (
	"fmt"
	"log"
	"time"

	"go.mau.fi/whatsmeow/types/events"
)

func (b *Bridge) handleEvent(rawEvt interface{}) {
	switch evt := rawEvt.(type) {
	case *events.Message:
		b.dispatchMessage(evt)
	case *events.JoinedGroup:
		// Sai assim que é adicionada, sem esperar a primeira mensagem.
		b.leaveGroup(evt.JID)
	case *events.MediaRetry:
		b.handleMediaRetry(evt)
	case *events.HistorySync:
		b.handleHistorySync(evt)
	case *events.Connected:
		b.clearConnectionError()
		log.Printf("[WhatsApp] Conectado e autenticado")
		b.avisarVolta()
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
		if id := b.wa().Store.ID; phone == "" && id != nil {
			phone = id.User
		}
		b.deleteSessionStore()

		if phone != "" {
			go func(targetPhone string) {
				time.Sleep(3 * time.Second)
				log.Printf("[WhatsApp] Sessão caiu. Tentando gerar novo pairing code para %s...\n", maskID(targetPhone))
				_, err := b.requestPairingCode(targetPhone)
				if err != nil {
					log.Printf("[WhatsApp] Erro ao gerar pairing code pós-logout: %v\n", err)
					b.notifyGleamEvent(map[string]interface{}{
						"evento": "whatsapp_down",
						"motivo": fmt.Sprintf("Sessão desconectada. Falha ao gerar pairing code: %v", err),
					})
				} else {
					log.Printf("[WhatsApp] Novo pairing code pós-logout gerado para %s\n", maskID(targetPhone))
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
	c := b.wa()
	if c == nil || c.Store == nil {
		return &APIError{
			Code:    "whatsapp_client_unavailable",
			Message: "cliente whatsmeow não inicializado",
		}
	}
	if c.Store.ID == nil {
		return &APIError{
			Code:    "whatsapp_session_missing",
			Message: "sessão WhatsApp ausente; novo pareamento necessário",
		}
	}
	if !c.IsConnected() {
		return &APIError{
			Code:    "whatsapp_disconnected",
			Message: "cliente WhatsApp desconectado ou ainda não autenticado",
		}
	}
	if !c.IsLoggedIn() {
		return &APIError{
			Code:    "whatsapp_unauthenticated",
			Message: "cliente WhatsApp conectado mas não autenticado",
		}
	}
	return nil
}
