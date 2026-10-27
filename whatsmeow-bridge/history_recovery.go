package main

import (
	"log"
	"sort"
	"time"

	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
)

// Recuperação das mensagens enviadas enquanto a sessão estava fora do ar.
//
// Depois de um logout e novo pareamento, o WhatsApp não reentrega o que
// chegou sem aparelho vinculado: essas mensagens só aparecem no history sync.
// De cada conversa privada, a ponte reaproveita as mensagens do usuário
// posteriores à última resposta da Amélie. O que já foi respondido fica antes
// dessa resposta; o que a ponte já entregou é barrado pela deduplicação da
// webhook_queue e, no Gleam, pela de mensagens_recebidas.

// historyRecoveryMaxAge acompanha idade_maxima_mensagem_s do Gleam, que
// ignora mensagens mais antigas que isso.
const historyRecoveryMaxAge = 48 * time.Hour

// pendingHistoryMessages devolve, em ordem cronológica, as mensagens do
// usuário de uma conversa que vieram depois da última resposta da Amélie e
// estão dentro de historyRecoveryMaxAge.
func pendingHistoryMessages(msgs []*events.Message, now time.Time) []*events.Message {
	var lastReply time.Time
	for _, msg := range msgs {
		if msg.Info.IsFromMe && msg.Info.Timestamp.After(lastReply) {
			lastReply = msg.Info.Timestamp
		}
	}
	oldest := now.Add(-historyRecoveryMaxAge)

	var pending []*events.Message
	for _, msg := range msgs {
		ts := msg.Info.Timestamp
		if msg.Info.IsFromMe || msg.Message == nil || !ts.After(lastReply) || ts.Before(oldest) {
			continue
		}
		pending = append(pending, msg)
	}
	sort.SliceStable(pending, func(i, j int) bool {
		return pending[i].Info.Timestamp.Before(pending[j].Info.Timestamp)
	})
	return pending
}

func (b *Bridge) handleHistorySync(evt *events.HistorySync) {
	if evt.Data == nil || b.client == nil {
		return
	}

	now := time.Now()
	var pending []*events.Message
	for _, conv := range evt.Data.GetConversations() {
		chat, err := types.ParseJID(conv.GetID())
		if err != nil || chatPolicyFor(chat.Server) != chatAccept {
			continue
		}
		parsed := make([]*events.Message, 0, len(conv.GetMessages()))
		for _, historyMsg := range conv.GetMessages() {
			msg, err := b.client.ParseWebMessage(chat, historyMsg.GetMessage())
			if err != nil {
				continue
			}
			parsed = append(parsed, msg)
		}
		pending = append(pending, pendingHistoryMessages(parsed, now)...)
	}
	if len(pending) == 0 {
		return
	}
	sort.SliceStable(pending, func(i, j int) bool {
		return pending[i].Info.Timestamp.Before(pending[j].Info.Timestamp)
	})

	log.Printf("[WhatsApp] History sync: %d mensagem(ns) sem resposta a recuperar", len(pending))
	// Fora do handler: o download de mídia não pode segurar as mensagens novas.
	go b.recoverHistoryMessages(pending)
}

// recoverHistoryMessages entrega as mensagens recuperadas uma a uma. Os
// pacotes de history sync chegam em sequência e podem repetir mensagens; o
// mutex mantém a ordem entre pacotes e o conjunto evita baixar a mesma mídia
// duas vezes.
func (b *Bridge) recoverHistoryMessages(msgs []*events.Message) {
	b.historyMu.Lock()
	defer b.historyMu.Unlock()
	if b.historySeen == nil {
		b.historySeen = make(map[types.MessageID]struct{})
	}

	for _, msg := range msgs {
		if _, seen := b.historySeen[msg.Info.ID]; seen {
			continue
		}
		b.historySeen[msg.Info.ID] = struct{}{}
		b.processMessage(msg)
	}
}
