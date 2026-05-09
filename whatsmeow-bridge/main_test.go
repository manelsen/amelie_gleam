package main

import (
	"fmt"
	"net"
	"strings"
	"testing"

	"go.mau.fi/whatsmeow"
	waProto "go.mau.fi/whatsmeow/binary/proto"
	"google.golang.org/protobuf/proto"
)

func TestClassifyDocumentMedia(t *testing.T) {
	tests := []struct {
		name         string
		rawMime      string
		fileName     string
		wantType     string
		wantMimeType string
	}{
		{
			name:         "keeps explicit audio mime",
			rawMime:      "audio/mpeg",
			fileName:     "reuniao.bin",
			wantType:     "audio",
			wantMimeType: "audio/mpeg",
		},
		{
			name:         "normalizes mime parameters",
			rawMime:      "audio/ogg; codecs=opus",
			fileName:     "gravacao.ogg",
			wantType:     "audio",
			wantMimeType: "audio/ogg",
		},
		{
			name:         "infers audio from octet stream file name",
			rawMime:      "application/octet-stream",
			fileName:     "REUNIAO.MP3",
			wantType:     "audio",
			wantMimeType: "audio/mpeg",
		},
		{
			name:         "infers audio from generic ogg mime",
			rawMime:      "application/ogg",
			fileName:     "mensagem.opus",
			wantType:     "audio",
			wantMimeType: "audio/ogg",
		},
		{
			name:         "infers image from empty mime",
			rawMime:      "",
			fileName:     "foto.webp",
			wantType:     "imagem",
			wantMimeType: "image/webp",
		},
		{
			name:         "keeps pdf as document",
			rawMime:      "application/pdf",
			fileName:     "contrato.pdf",
			wantType:     "documento",
			wantMimeType: "application/pdf",
		},
		{
			name:         "keeps unknown binary as document",
			rawMime:      "application/octet-stream",
			fileName:     "arquivo.bin",
			wantType:     "documento",
			wantMimeType: "application/octet-stream",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			gotType, gotMimeType := classifyDocumentMedia(tt.rawMime, tt.fileName)
			if gotType != tt.wantType {
				t.Fatalf("media type = %q, want %q", gotType, tt.wantType)
			}
			if gotMimeType != tt.wantMimeType {
				t.Fatalf("mime type = %q, want %q", gotMimeType, tt.wantMimeType)
			}
		})
	}
}

func TestNormalizeStickerMime(t *testing.T) {
	tests := []struct {
		name string
		raw  string
		want string
	}{
		{name: "defaults empty mime to webp", raw: "", want: "image/webp"},
		{name: "normalizes mime parameters", raw: "image/webp; codecs=vp8", want: "image/webp"},
		{name: "keeps explicit lottie mime", raw: "application/x-tgsticker", want: "application/x-tgsticker"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := normalizeStickerMime(tt.raw)
			if got != tt.want {
				t.Fatalf("mime = %q, want %q", got, tt.want)
			}
		})
	}
}

func TestShouldRequestMediaRetry(t *testing.T) {
	tests := []struct {
		name string
		err  error
		want bool
	}{
		{
			name: "http 404",
			err:  whatsmeow.ErrMediaDownloadFailedWith404,
			want: true,
		},
		{
			name: "wrapped dns not found",
			err: fmt.Errorf(
				"failed to download media from last host: %w",
				&net.DNSError{Err: "no such host", Name: "a.whatsapp.net", IsNotFound: true},
			),
			want: true,
		},
		{
			name: "string no such host fallback",
			err:  fmt.Errorf("lookup a.whatsapp.net on 127.0.0.11:53: no such host"),
			want: true,
		},
		{
			name: "unrelated error",
			err:  fmt.Errorf("connection reset by peer"),
			want: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := shouldRequestMediaRetry(tt.err)
			if got != tt.want {
				t.Fatalf("shouldRequestMediaRetry() = %v, want %v", got, tt.want)
			}
		})
	}
}

func TestStickerPromptContext(t *testing.T) {
	sticker := &waProto.StickerMessage{
		IsAnimated:         proto.Bool(true),
		AccessibilityLabel: proto.String("personagem sorrindo"),
	}

	got := stickerPromptContext(sticker)
	for _, want := range []string{"figurinha/sticker", "animada", "personagem sorrindo"} {
		if !strings.Contains(got, want) {
			t.Fatalf("context %q does not contain %q", got, want)
		}
	}
}

func TestStickerThumbnailFallback(t *testing.T) {
	sticker := &waProto.StickerMessage{
		PngThumbnail: []byte{0x89, 0x50, 0x4e, 0x47},
	}

	data, mime, ok := stickerThumbnailFallback(sticker)
	if !ok {
		t.Fatal("expected thumbnail fallback")
	}
	if mime != "image/png" {
		t.Fatalf("mime = %q, want image/png", mime)
	}
	if string(data) != string(sticker.GetPngThumbnail()) {
		t.Fatalf("data = %v, want %v", data, sticker.GetPngThumbnail())
	}
}

func TestStickerThumbnailFallbackMissing(t *testing.T) {
	_, _, ok := stickerThumbnailFallback(&waProto.StickerMessage{})
	if ok {
		t.Fatal("did not expect thumbnail fallback")
	}
}
