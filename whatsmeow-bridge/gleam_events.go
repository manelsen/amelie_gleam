package main

import (
	"encoding/json"
	"fmt"
	"log"
	"strings"
	"time"
)

// avisarVolta manda whatsapp_up ao Gleam na primeira conexão depois de um
// aviso de queda (ou do início do processo). Reconexões automáticas, que não
// geraram aviso de queda, não geram aviso de volta.
func (b *Bridge) avisarVolta() {
	b.eventosMu.Lock()
	defer b.eventosMu.Unlock()
	if !b.avisoQuedaPendente.CompareAndSwap(true, false) {
		return
	}
	b.geracaoVolta++
	b.enfileirarEventoLocked(map[string]interface{}{"evento": "whatsapp_up"}, b.geracaoVolta)
}

// Esperas entre tentativas de entregar um evento ao Gleam: somam cerca de
// dois minutos, o bastante para o Gleam subir quando a ponte reinicia junto.
var notifyRetryDelays = []time.Duration{
	1 * time.Second, 2 * time.Second, 4 * time.Second, 8 * time.Second,
	15 * time.Second, 15 * time.Second, 15 * time.Second, 15 * time.Second,
	15 * time.Second, 15 * time.Second,
}

// Espera até tentar de novo um aviso de volta que não chegou ao Gleam.
var voltaRetryDelay = time.Minute

type eventoGleam struct {
	nome  interface{}
	dados []byte
	// geracao só vale para whatsapp_up; ver Bridge.geracaoVolta.
	geracao uint64
}

// notifyGleamEvent enfileira o evento para o Gleam. Uma fila só, entregue em
// ordem por um único worker: um aviso de queda em retentativa não pode chegar
// ao admin depois do aviso de volta.
func (b *Bridge) notifyGleamEvent(payload map[string]interface{}) {
	// O indicador e a fila mudam juntos: um Connected no meio não pode
	// enfileirar a volta antes desta queda.
	b.eventosMu.Lock()
	defer b.eventosMu.Unlock()
	switch payload["evento"] {
	case "whatsapp_down", "pairing_code":
		b.avisoQuedaPendente.Store(true)
	}
	b.enfileirarEventoLocked(payload, 0)
}

func (b *Bridge) enfileirarEventoLocked(payload map[string]interface{}, geracao uint64) {
	if b.cfg.GleamURL == "" {
		return
	}
	data, err := json.Marshal(payload)
	if err != nil {
		log.Printf("[Bridge] Erro ao codificar evento para o Gleam: %v\n", err)
		return
	}
	if b.eventos == nil {
		b.eventos = make(chan eventoGleam, 64)
		go b.entregarEventos(b.eventos)
	}
	select {
	case b.eventos <- eventoGleam{nome: payload["evento"], dados: data, geracao: geracao}:
	default:
		log.Printf("[Bridge] Fila de eventos para o Gleam cheia; evento '%v' descartado\n", payload["evento"])
		if payload["evento"] == "whatsapp_up" {
			b.religarVoltaLocked()
		}
	}
}

func (b *Bridge) entregarEventos(eventos <-chan eventoGleam) {
	eventURL := strings.Replace(b.cfg.GleamURL, "/webhook", "/webhook/bridge-event", 1)
	for evt := range eventos {
		if b.entregarEvento(eventURL, evt) || evt.nome != "whatsapp_up" {
			continue
		}
		b.voltaNaoEntregue(evt.geracao)
	}
}

// voltaNaoEntregue trata um whatsapp_up que esgotou as tentativas. Se outro
// aviso de volta já foi enfileirado depois dele, não faz nada: o mais novo
// responde pela volta.
func (b *Bridge) voltaNaoEntregue(geracao uint64) {
	b.eventosMu.Lock()
	defer b.eventosMu.Unlock()
	if geracao != b.geracaoVolta {
		return
	}
	b.religarVoltaLocked()
}

// religarVoltaLocked deixa o aviso de volta pendente e agenda uma nova
// tentativa, que sai se a sessão continuar conectada.
func (b *Bridge) religarVoltaLocked() {
	b.avisoQuedaPendente.Store(true)
	time.AfterFunc(voltaRetryDelay, b.avisarVoltaSeConectado)
}

func (b *Bridge) avisarVoltaSeConectado() {
	// IsLoggedIn sozinho pode seguir verdadeiro com o socket caído.
	if c := b.wa(); c != nil && c.IsConnected() && c.IsLoggedIn() {
		b.avisarVolta()
	}
}

func (b *Bridge) entregarEvento(eventURL string, evt eventoGleam) bool {
	total := len(notifyRetryDelays) + 1
	for attempt := 1; attempt <= total; attempt++ {
		resp, err := b.postAuthenticated(eventURL, evt.dados)
		if err == nil {
			_ = resp.Body.Close()
			if resp.StatusCode >= 200 && resp.StatusCode < 300 {
				log.Printf("[Bridge] Evento '%v' notificado ao Gleam com sucesso\n", evt.nome)
				return true
			}
			err = fmt.Errorf("Gleam retornou status %d", resp.StatusCode)
		}
		log.Printf("[Bridge] Falha ao notificar evento '%v' ao Gleam (tentativa %d/%d): %v\n", evt.nome, attempt, total, err)
		if attempt < total {
			time.Sleep(notifyRetryDelays[attempt-1])
		}
	}
	return false
}
