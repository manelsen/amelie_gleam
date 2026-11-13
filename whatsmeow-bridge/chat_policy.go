package main

import (
	"context"
	"log"
	"sync"
	"time"

	"go.mau.fi/whatsmeow/types"
)

// A Amélie só atende conversas privadas. Antes, a política "sem grupos"
// existia só no Telegram; no WhatsApp, quem adicionasse o número a um grupo
// ganhava um bot de grupo funcionando, pago pelo dono.
type chatPolicy int

const (
	// chatAccept: conversa privada, processa normalmente.
	chatAccept chatPolicy = iota
	// chatLeave: grupo. Descarta a mensagem e sai do grupo.
	chatLeave
	// chatDrop: broadcast/status, canal, bot e afins. Só descarta; não há de
	// onde sair (e LeaveGroup em status@broadcast daria erro).
	chatDrop
)

// chatPolicyFor decide pelo servidor do JID do chat. Os valores são os de
// go.mau.fi/whatsmeow/types (DefaultUserServer, HiddenUserServer, ...),
// repetidos como texto para esta regra ser testável isoladamente.
// IsGroup não serve: ele também é true para listas de transmissão.
func chatPolicyFor(server string) chatPolicy {
	switch server {
	case "s.whatsapp.net", "lid", "hosted", "hosted.lid":
		return chatAccept
	case "g.us":
		return chatLeave
	default:
		return chatDrop
	}
}

// groupLeaveRetry é o intervalo mínimo entre tentativas de sair do mesmo
// grupo, para uma rajada de mensagens não virar uma rajada de LeaveGroup.
const groupLeaveRetry = 10 * time.Minute

// leaveAttempts registra a última tentativa de saída por grupo.
type leaveAttempts struct {
	mu   sync.Mutex
	last map[string]time.Time
}

func newLeaveAttempts() *leaveAttempts {
	return &leaveAttempts{last: map[string]time.Time{}}
}

// shouldAttempt diz se vale tentar sair do grupo agora e, se sim, registra
// a tentativa. Entradas antigas são removidas para o mapa não crescer.
func (a *leaveAttempts) shouldAttempt(group string, now time.Time) bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	for g, t := range a.last {
		if now.Sub(t) >= groupLeaveRetry {
			delete(a.last, g)
		}
	}
	if _, recent := a.last[group]; recent {
		return false
	}
	a.last[group] = now
	return true
}

// leaveGroup sai do grupo em segundo plano, no máximo uma tentativa por
// grupo a cada groupLeaveRetry. Não loga o JID: grupos antigos carregam o
// telefone de quem os criou no identificador.
func (b *Bridge) leaveGroup(group types.JID) {
	if b.wa() == nil || b.groupLeaves == nil {
		return
	}
	if !b.groupLeaves.shouldAttempt(group.String(), time.Now()) {
		return
	}
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := b.wa().LeaveGroup(ctx, group); err != nil {
			log.Printf("[Grupos] Falha ao sair de um grupo (nova tentativa em até %s): %v", groupLeaveRetry, err)
			return
		}
		log.Printf("[Grupos] A Amélie foi adicionada a um grupo e saiu, como manda a política")
	}()
}
