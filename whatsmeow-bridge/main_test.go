package main

import "testing"

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
