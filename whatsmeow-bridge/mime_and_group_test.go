package main

import (
	"errors"
	"testing"
	"time"

	"go.mau.fi/whatsmeow/types"
)

func TestSanitizeMime(t *testing.T) {
	cases := map[string]string{
		"":                           "",
		"image/jpeg":                 "image/jpeg",
		"audio/ogg; codecs=opus":     "audio/ogg",
		"Video/MP4":                  "video/mp4",
		"application/vnd.ms-excel":   "application/vnd.ms-excel",
		"video/mp4\r\nX-Injetado: 1": "application/octet-stream",
		`video/mp4"}},"x":{"y":"`:    "application/octet-stream",
		"semtipo":                    "application/octet-stream",
	}
	for in, want := range cases {
		if got := sanitizeMime(in); got != want {
			t.Fatalf("sanitizeMime(%q) = %q, esperava %q", in, got, want)
		}
	}
}

func TestGroupNameCacheFetchesOnceUntilExpiry(t *testing.T) {
	agora := time.Unix(1_000_000, 0)
	c := newGroupNameCache()
	c.now = func() time.Time { return agora }

	chamadas := 0
	fetch := func() (string, error) {
		chamadas++
		return "Família", nil
	}

	if got := c.get("123@g.us", fetch); got != "Família" {
		t.Fatalf("nome errado: %q", got)
	}
	c.get("123@g.us", fetch)
	if chamadas != 1 {
		t.Fatalf("esperava 1 consulta com cache válido, veio %d", chamadas)
	}

	agora = agora.Add(groupNameTTL + time.Second)
	c.get("123@g.us", fetch)
	if chamadas != 2 {
		t.Fatalf("esperava nova consulta após expirar, veio %d", chamadas)
	}
}

func TestGroupNameCacheDoesNotStoreErrors(t *testing.T) {
	c := newGroupNameCache()
	falha := func() (string, error) { return "", errors.New("offline") }
	if got := c.get("123@g.us", falha); got != "" {
		t.Fatalf("em erro deveria devolver vazio, veio %q", got)
	}
	if got := c.get("123@g.us", func() (string, error) { return "Grupo X", nil }); got != "Grupo X" {
		t.Fatalf("erro não deveria ter ficado em cache, veio %q", got)
	}
}

func TestLookupGroupNameWithoutClientIsEmpty(t *testing.T) {
	// Testes existentes criam Bridge{} sem cliente nem cache; não pode quebrar.
	b := &Bridge{}
	if got := b.lookupGroupName(types.NewJID("123", types.GroupServer)); got != "" {
		t.Fatalf("sem cliente deveria devolver vazio, veio %q", got)
	}
}
