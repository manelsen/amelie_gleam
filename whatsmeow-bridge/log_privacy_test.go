package main

import (
	"bytes"
	"log"
	"os"
	"strings"
	"testing"
)

func TestMaskID(t *testing.T) {
	cases := map[string]string{
		"5531999990000":                    "5531****0000",
		"5531999990000@s.whatsapp.net":     "5531****0000@s.whatsapp.net",
		"5531999990000:12@s.whatsapp.net":  "5531****0000:12@s.whatsapp.net",
		"5531999990000.0:7@s.whatsapp.net": "5531****0000.0:7@s.whatsapp.net",
		"120363012345678901@g.us":          "1203****8901@g.us",
		"123456@lid":                       "****@lid",
		"":                                 "****",
	}
	for in, want := range cases {
		if got := maskID(in); got != want {
			t.Fatalf("maskID(%q) = %q, esperava %q", in, got, want)
		}
	}
}

func TestLogPairingCodeHidesCodeByDefault(t *testing.T) {
	t.Setenv("PAIRING_CODE_IN_LOG", "")
	var buf bytes.Buffer
	log.SetOutput(&buf)
	defer log.SetOutput(os.Stderr)

	logPairingCode("5531999990000", "ABCD-1234")

	out := buf.String()
	if strings.Contains(out, "ABCD-1234") {
		t.Fatalf("código de pareamento vazou no log: %s", out)
	}
	if strings.Contains(out, "5531999990000") {
		t.Fatalf("telefone completo no log: %s", out)
	}
}

func TestLogPairingCodeOptIn(t *testing.T) {
	t.Setenv("PAIRING_CODE_IN_LOG", "1")
	var buf bytes.Buffer
	log.SetOutput(&buf)
	defer log.SetOutput(os.Stderr)

	logPairingCode("5531999990000", "ABCD-1234")

	if !strings.Contains(buf.String(), "ABCD-1234") {
		t.Fatal("com PAIRING_CODE_IN_LOG=1 o código deveria aparecer")
	}
}
