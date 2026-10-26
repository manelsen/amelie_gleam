package main

import (
	"testing"
	"time"

	"go.mau.fi/whatsmeow/types"
)

func TestChatPolicyFor(t *testing.T) {
	cases := map[string]chatPolicy{
		"s.whatsapp.net": chatAccept,
		"lid":            chatAccept,
		"hosted":         chatAccept,
		"hosted.lid":     chatAccept,
		"g.us":           chatLeave,
		// IsGroup é true também para broadcast; dele não se sai.
		"broadcast":  chatDrop,
		"newsletter": chatDrop,
		"bot":        chatDrop,
		"":           chatDrop,
	}
	for server, want := range cases {
		if got := chatPolicyFor(server); got != want {
			t.Fatalf("chatPolicyFor(%q) = %v, esperava %v", server, got, want)
		}
	}
}

func TestLeaveAttemptsThrottlesPerGroup(t *testing.T) {
	a := newLeaveAttempts()
	agora := time.Unix(1_000_000, 0)

	if !a.shouldAttempt("1@g.us", agora) {
		t.Fatal("primeira tentativa deveria passar")
	}
	if a.shouldAttempt("1@g.us", agora.Add(time.Minute)) {
		t.Fatal("rajada de mensagens não pode gerar nova tentativa")
	}
	if !a.shouldAttempt("2@g.us", agora.Add(time.Minute)) {
		t.Fatal("outro grupo deveria ter sua própria tentativa")
	}
	if !a.shouldAttempt("1@g.us", agora.Add(groupLeaveRetry)) {
		t.Fatal("depois do intervalo, deveria tentar de novo")
	}
}

func TestLeaveAttemptsForgetsOldEntries(t *testing.T) {
	a := newLeaveAttempts()
	agora := time.Unix(1_000_000, 0)
	for i := 0; i < 100; i++ {
		a.shouldAttempt(time.Duration(i).String()+"@g.us", agora)
	}
	a.shouldAttempt("novo@g.us", agora.Add(groupLeaveRetry))
	if len(a.last) != 1 {
		t.Fatalf("entradas antigas deveriam sair do mapa, restaram %d", len(a.last))
	}
}

func TestLeaveGroupWithoutClientIsNoop(t *testing.T) {
	// Testes existentes criam Bridge{} sem cliente; não pode quebrar.
	b := &Bridge{}
	b.leaveGroup(types.NewJID("123", types.GroupServer))
}
