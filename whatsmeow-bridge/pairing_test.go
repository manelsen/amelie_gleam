package main

import (
	"testing"
	"time"

	"go.mau.fi/whatsmeow"
)

func TestRenewPairingIgnoresSupersededCode(t *testing.T) {
	// Sem cliente: se tentasse renovar, entraria em pânico.
	bridge := &Bridge{pairingGen: 2}

	bridge.renewPairing(1, "5531999990000", pairingAutoRenewals)

	if bridge.pairingGen != 2 {
		t.Fatalf("pairingGen = %d, esperado 2", bridge.pairingGen)
	}
	if err := bridge.currentConnectionError(); err != nil {
		t.Fatalf("erro de conexão inesperado: %#v", err)
	}
}

func TestRenewPairingGivesUpAfterRenewals(t *testing.T) {
	bridge := &Bridge{pairingGen: 1}

	bridge.renewPairing(1, "5531999990000", 0)

	err := bridge.currentConnectionError()
	if err == nil || err.Code != "pairing_timeout" {
		t.Fatalf("erro de conexão = %#v, esperado pairing_timeout", err)
	}
}

func TestWatchPairingTimeoutOfSupersededCodeDoesNothing(t *testing.T) {
	bridge := &Bridge{pairingGen: 2}
	qrChan := make(chan whatsmeow.QRChannelItem, 2)
	qrChan <- whatsmeow.QRChannelItem{Event: whatsmeow.QRChannelEventCode}
	qrChan <- whatsmeow.QRChannelTimeout

	done := make(chan struct{})
	go func() {
		bridge.watchPairing(1, "5531999990000", qrChan, make(chan struct{}), pairingAutoRenewals)
		close(done)
	}()

	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("watchPairing não terminou após o timeout")
	}
	if err := bridge.currentConnectionError(); err != nil {
		t.Fatalf("erro de conexão inesperado: %#v", err)
	}
}

func TestWatchPairingStopsWhenSuperseded(t *testing.T) {
	bridge := &Bridge{}
	stop := make(chan struct{})
	close(stop)

	done := make(chan struct{})
	go func() {
		bridge.watchPairing(1, "5531999990000", make(chan whatsmeow.QRChannelItem), stop, 0)
		close(done)
	}()

	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("watchPairing não parou ao ser substituído")
	}
}
