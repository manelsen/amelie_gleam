package main

import (
	"testing"
	"time"

	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
	"google.golang.org/protobuf/proto"
)

func historyMsg(id string, fromMe bool, ts time.Time) *events.Message {
	return &events.Message{
		Info: types.MessageInfo{
			MessageSource: types.MessageSource{IsFromMe: fromMe},
			ID:            types.MessageID(id),
			Timestamp:     ts,
		},
		Message: &waE2E.Message{Conversation: proto.String("oi")},
	}
}

func ids(msgs []*events.Message) []string {
	out := make([]string, 0, len(msgs))
	for _, msg := range msgs {
		out = append(out, string(msg.Info.ID))
	}
	return out
}

func TestPendingHistoryMessagesKeepsOnlyAfterLastReply(t *testing.T) {
	now := time.Date(2026, 10, 27, 20, 0, 0, 0, time.UTC)
	ago := func(m int) time.Time { return now.Add(-time.Duration(m) * time.Minute) }

	// Ordem do history sync não é garantida: mais nova primeiro aqui.
	msgs := []*events.Message{
		historyMsg("depois-2", false, ago(1)),
		historyMsg("depois-1", false, ago(5)),
		historyMsg("resposta", true, ago(10)),
		historyMsg("respondida", false, ago(11)),
	}

	got := ids(pendingHistoryMessages(msgs, now))
	want := []string{"depois-1", "depois-2"}
	if len(got) != len(want) || got[0] != want[0] || got[1] != want[1] {
		t.Fatalf("pendentes = %v, esperado %v", got, want)
	}
}

func TestPendingHistoryMessagesWithoutReplyTakesAllRecent(t *testing.T) {
	now := time.Date(2026, 10, 27, 20, 0, 0, 0, time.UTC)

	msgs := []*events.Message{
		historyMsg("antiga", false, now.Add(-historyRecoveryMaxAge-time.Minute)),
		historyMsg("recente", false, now.Add(-time.Hour)),
	}

	got := ids(pendingHistoryMessages(msgs, now))
	if len(got) != 1 || got[0] != "recente" {
		t.Fatalf("pendentes = %v, esperado [recente]", got)
	}
}

func TestPendingHistoryMessagesSkipsEmptyAndAnswered(t *testing.T) {
	now := time.Date(2026, 10, 27, 20, 0, 0, 0, time.UTC)
	vazia := historyMsg("vazia", false, now.Add(-time.Minute))
	vazia.Message = nil

	msgs := []*events.Message{
		historyMsg("respondida", false, now.Add(-3*time.Minute)),
		historyMsg("resposta", true, now.Add(-2*time.Minute)),
		vazia,
	}

	if got := pendingHistoryMessages(msgs, now); len(got) != 0 {
		t.Fatalf("pendentes = %v, esperado nenhuma", ids(got))
	}
}

func TestRecoverHistoryMessagesSkipsRepeated(t *testing.T) {
	bridge := &Bridge{}
	msg := historyMsg("repetida", false, time.Now())
	bridge.historySeen = map[types.MessageID]struct{}{msg.Info.ID: {}}

	// Já vista: não chega a processMessage, que precisaria de cliente e fila.
	bridge.recoverHistoryMessages([]*events.Message{msg})
}
