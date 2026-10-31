package main

import (
	"context"
	"fmt"
	"log"
	"time"

	"go.mau.fi/whatsmeow"
)

// Um código de pareamento só vale enquanto dura o canal de QR da conexão que
// o pediu: um ref de 60 s e mais cinco de 20 s, cerca de 160 s. Quando os refs
// acabam, o whatsmeow derruba o websocket e o código morre. Um novo PairPhone
// também invalida o código anterior. Por isso a ponte renova o código sozinha
// algumas vezes, e cada pedido novo encerra o pareamento em andamento.
const pairingAutoRenewals = 3

// requestPairingCode gera um código novo, avisa o Gleam (que o repassa ao
// admin pelo Telegram) e encerra qualquer pareamento anterior.
func (b *Bridge) requestPairingCode(phone string) (string, error) {
	b.pairingMu.Lock()
	defer b.pairingMu.Unlock()
	return b.pairLocked(cleanPhoneNumber(phone), pairingAutoRenewals)
}

func (b *Bridge) pairLocked(phone string, renewals int) (string, error) {
	if b.client.IsLoggedIn() {
		return "", fmt.Errorf("já autenticado")
	}

	b.pairingGen++
	gen := b.pairingGen
	if b.pairingStop != nil {
		close(b.pairingStop)
	}
	stop := make(chan struct{})
	b.pairingStop = stop

	// Cliente novo a cada código: o canal de QR do anterior derrubaria a
	// conexão deste ao expirar.
	b.deleteSessionStore()

	qrChan, err := b.client.GetQRChannel(context.Background())
	if err != nil {
		return "", fmt.Errorf("abrir canal de pareamento: %w", err)
	}
	if err := b.client.Connect(); err != nil {
		return "", fmt.Errorf("conectar websocket: %w", err)
	}

	select {
	case evt, ok := <-qrChan:
		if !ok {
			return "", fmt.Errorf("canal de autenticação fechou antes do pareamento")
		}
		if evt.Event == whatsmeow.QRChannelSuccess.Event {
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
	logPairingCode(phone, code)

	go b.watchPairing(gen, phone, qrChan, stop, renewals)
	return code, nil
}

func (b *Bridge) watchPairing(gen uint64, phone string, qrChan <-chan whatsmeow.QRChannelItem, stop <-chan struct{}, renewals int) {
	for {
		select {
		case <-stop:
			return
		case evt, ok := <-qrChan:
			if !ok {
				return
			}
			switch evt.Event {
			case whatsmeow.QRChannelEventCode:
			case whatsmeow.QRChannelSuccess.Event:
				log.Printf("[WhatsApp] Autenticação via Pairing Code realizada com sucesso!")
				return
			case whatsmeow.QRChannelTimeout.Event:
				b.renewPairing(gen, phone, renewals)
				return
			default:
				log.Printf("[WhatsApp] Evento de autenticação: %s\n", evt.Event)
			}
		}
	}
}

// renewPairing troca o código expirado por outro, se ninguém pediu um código
// mais novo nesse meio-tempo. Esgotadas as renovações, avisa o admin.
func (b *Bridge) renewPairing(gen uint64, phone string, renewals int) {
	b.pairingMu.Lock()
	defer b.pairingMu.Unlock()
	if gen != b.pairingGen {
		return
	}

	if renewals <= 0 {
		log.Printf("[WhatsApp] Códigos de pareamento expiraram sem confirmação no celular. Aguardando nova solicitação via /parear...")
		b.setConnectionError("pairing_timeout", "pairing code expirou sem confirmação no celular")
		b.notifyGleamEvent(map[string]interface{}{
			"evento": "whatsapp_down",
			"motivo": "os códigos de pareamento expiraram sem confirmação no celular",
		})
		return
	}

	log.Printf("[WhatsApp] Código de pareamento expirou; gerando outro (%d renovação(ões) restante(s))", renewals-1)
	if _, err := b.pairLocked(phone, renewals-1); err != nil {
		log.Printf("[WhatsApp] Erro ao renovar pairing code: %v\n", err)
		b.notifyGleamEvent(map[string]interface{}{
			"evento": "whatsapp_down",
			"motivo": fmt.Sprintf("Falha ao renovar o código de pareamento: %v", err),
		})
	}
}
