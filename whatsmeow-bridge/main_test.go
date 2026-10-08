package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"go.mau.fi/whatsmeow"
	waProto "go.mau.fi/whatsmeow/binary/proto"
	"go.mau.fi/whatsmeow/store"
	"go.mau.fi/whatsmeow/types/events"
	"google.golang.org/protobuf/proto"
)

func TestHandleEventIgnoresHistorySync(t *testing.T) {
	bridge := &Bridge{}

	bridge.handleEvent(&events.HistorySync{})
}

func TestHandleHealthReportsMissingSession(t *testing.T) {
	bridge := bridgeWithoutSession()
	recorder := httptest.NewRecorder()

	bridge.handleHealth(recorder, httptest.NewRequest(http.MethodGet, "/health", nil))

	if recorder.Code != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want %d", recorder.Code, http.StatusServiceUnavailable)
	}
	var response HealthResponse
	if err := json.NewDecoder(recorder.Body).Decode(&response); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if response.Status != "unavailable" || response.LoggedIn {
		t.Fatalf("unexpected health response: %#v", response)
	}
	if response.APIError == nil || response.Code != "whatsapp_session_missing" {
		t.Fatalf("error = %#v, want whatsapp_session_missing", response.APIError)
	}
}

func TestLoggedOutReasonReachesHealth(t *testing.T) {
	bridge := bridgeWithoutSession()
	bridge.handleEvent(&events.LoggedOut{
		Reason: events.ConnectFailureLoggedOut,
	})
	recorder := httptest.NewRecorder()

	bridge.handleHealth(recorder, httptest.NewRequest(http.MethodGet, "/health", nil))

	var response HealthResponse
	if err := json.NewDecoder(recorder.Body).Decode(&response); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if response.APIError == nil || response.Code != "whatsapp_logged_out" {
		t.Fatalf("error = %#v, want whatsapp_logged_out", response.APIError)
	}
	if !strings.Contains(response.Message, "401") || !strings.Contains(response.Message, "novo pareamento") {
		t.Fatalf("error message = %q, want logout reason and recovery action", response.Message)
	}
}

func TestHandleSendReturnsExplicitSessionFailure(t *testing.T) {
	bridge := bridgeWithoutSession()
	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(
		http.MethodPost,
		"/send",
		strings.NewReader(`{"chat_id":"5511999999999@s.whatsapp.net","text":"oi"}`),
	)

	bridge.handleSend(recorder, request)

	if recorder.Code != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want %d", recorder.Code, http.StatusServiceUnavailable)
	}
	var response ErrorResponse
	if err := json.NewDecoder(recorder.Body).Decode(&response); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if response.OK || response.Code != "whatsapp_session_missing" {
		t.Fatalf("unexpected error response: %#v", response)
	}
}

func bridgeWithoutSession() *Bridge {
	return &Bridge{
		client: &whatsmeow.Client{Store: &store.Device{}},
	}
}

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
			name: "download timeout",
			err:  context.DeadlineExceeded,
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

func TestMediaDownloadTimeout(t *testing.T) {
	if mediaDownloadTimeout("figurinha") <= mediaDownloadTimeout("imagem") {
		t.Fatalf("sticker timeout should be longer than image timeout")
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

func TestStickerMetadataFallbackPayload(t *testing.T) {
	sticker := &waProto.StickerMessage{
		AccessibilityLabel: proto.String("personagem sorrindo"),
		Emojis:             proto.String("😀"),
		Width:              proto.Uint32(512),
		Height:             proto.Uint32(512),
	}
	payload := IncomingWebhook{
		ChatID:    "chat",
		From:      "sender",
		MessageID: "msg",
		Tipo:      "sticker",
		Mime:      "image/webp",
		Dados:     "abc",
		Legenda:   "contexto",
	}

	got := stickerMetadataFallbackPayload(payload, sticker)
	if got.Tipo != "midia_indisponivel" {
		t.Fatalf("tipo = %q, want midia_indisponivel", got.Tipo)
	}
	if got.Mime != "" || got.Dados != "" || got.Legenda != "" {
		t.Fatalf("media fields should be cleared: %#v", got)
	}
	for _, want := range []string{"mídia veio indisponível", "personagem sorrindo", "😀", "512x512"} {
		if !strings.Contains(got.Text, want) {
			t.Fatalf("fallback text %q does not contain %q", got.Text, want)
		}
	}
}

func TestParseWebPMuxFrameCount(t *testing.T) {
	info := "Canvas size: 512 x 512\nNumber of frames: 27\n"

	got, ok := parseWebPMuxFrameCount(info)
	if !ok {
		t.Fatal("expected frame count to parse")
	}
	if got != 27 {
		t.Fatalf("frame count = %d, want 27", got)
	}
}

func TestParseWebPMuxFrameCountMissing(t *testing.T) {
	got, ok := parseWebPMuxFrameCount("Canvas size: 512 x 512\n")
	if ok {
		t.Fatalf("expected parse failure, got %d", got)
	}
}

func TestSampleFrameIndicesAllFrames(t *testing.T) {
	got := sampleFrameIndices(4, maxAnimatedStickerFrames)
	want := []int{1, 2, 3, 4}

	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("indices = %v, want %v", got, want)
	}
}

func TestSampleFrameIndicesSpansAnimation(t *testing.T) {
	got := sampleFrameIndices(27, maxAnimatedStickerFrames)

	if len(got) != maxAnimatedStickerFrames {
		t.Fatalf("len(indices) = %d, want %d", len(got), maxAnimatedStickerFrames)
	}
	if got[0] != 1 {
		t.Fatalf("first index = %d, want 1", got[0])
	}
	if got[len(got)-1] != 27 {
		t.Fatalf("last index = %d, want 27", got[len(got)-1])
	}
	for i := 1; i < len(got); i++ {
		if got[i] <= got[i-1] {
			t.Fatalf("indices should be strictly increasing: %v", got)
		}
	}
}

func TestContactSheetGrid(t *testing.T) {
	tests := []struct {
		frameCount int
		wantCols   int
		wantRows   int
	}{
		{frameCount: 1, wantCols: 1, wantRows: 1},
		{frameCount: 3, wantCols: 3, wantRows: 1},
		{frameCount: 16, wantCols: 4, wantRows: 4},
	}

	for _, tt := range tests {
		t.Run(fmt.Sprintf("%d_frames", tt.frameCount), func(t *testing.T) {
			gotCols, gotRows := contactSheetGrid(tt.frameCount)
			if gotCols != tt.wantCols || gotRows != tt.wantRows {
				t.Fatalf("grid = %dx%d, want %dx%d", gotCols, gotRows, tt.wantCols, tt.wantRows)
			}
		})
	}
}

func TestAttachMediaFileReplacesInlineData(t *testing.T) {
	b := &Bridge{}
	payload := IncomingWebhook{ChatID: "chat", Mime: "audio/ogg", Dados: "resto"}
	data := []byte("conteudo binario")

	if !b.attachMediaFile(&payload, "audio", "", data) {
		t.Fatal("attachMediaFile falhou")
	}
	defer os.Remove(payload.Caminho)

	if payload.Dados != "" {
		t.Fatalf("Dados deveria ficar vazio, veio %q", payload.Dados)
	}
	if !strings.HasPrefix(filepath.Base(payload.Caminho), mediaTempPrefix+"audio_") {
		t.Fatalf("caminho sem prefixo esperado: %s", payload.Caminho)
	}
	gravado, err := os.ReadFile(payload.Caminho)
	if err != nil {
		t.Fatalf("lendo arquivo: %v", err)
	}
	if string(gravado) != string(data) {
		t.Fatalf("conteudo gravado diferente: %q", gravado)
	}
}

func TestCleanupOrphanMediaFiles(t *testing.T) {
	dir := t.TempDir()
	antigo := filepath.Join(dir, mediaTempPrefix+"imagem_antigo")
	recente := filepath.Join(dir, mediaTempPrefix+"imagem_recente")
	alheio := filepath.Join(dir, "outro_arquivo")
	for _, path := range []string{antigo, recente, alheio} {
		if err := os.WriteFile(path, []byte("x"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	velho := time.Now().Add(-48 * time.Hour)
	for _, path := range []string{antigo, alheio} {
		if err := os.Chtimes(path, velho, velho); err != nil {
			t.Fatal(err)
		}
	}

	cleanupOrphanMediaFiles(dir, orphanMediaMaxAge)

	if _, err := os.Stat(antigo); !os.IsNotExist(err) {
		t.Fatalf("arquivo órfão antigo deveria ter sido removido: %v", err)
	}
	if _, err := os.Stat(recente); err != nil {
		t.Fatalf("arquivo recente deveria permanecer: %v", err)
	}
	if _, err := os.Stat(alheio); err != nil {
		t.Fatalf("arquivo sem prefixo deveria permanecer: %v", err)
	}
}

func TestCleanPhoneNumber(t *testing.T) {
	tests := []struct {
		input string
		want  string
	}{
		{"+55 (31) 98888-0000", "5531988880000"},
		{"31988880000", "5531988880000"},
		{"5531988880000", "5531988880000"},
		{"031988880000", "5531988880000"},
		{"(11) 97777-6666", "5511977776666"},
		{"(21) 3333-4444", "552133334444"},
		{"12025550123", "5512025550123"}, // 12 é DDD SP
	}
	for _, tc := range tests {
		got := cleanPhoneNumber(tc.input)
		if got != tc.want {
			t.Errorf("cleanPhoneNumber(%q) = %q, want %q", tc.input, got, tc.want)
		}
	}
}

func TestHandlePairPhoneRequiresPhone(t *testing.T) {
	bridge := &Bridge{}
	recorder := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/pair-phone", strings.NewReader(`{}`))
	bridge.handlePairPhone(recorder, req)

	if recorder.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want %d", recorder.Code, http.StatusBadRequest)
	}
	var resp PairPhoneResponse
	if err := json.NewDecoder(recorder.Body).Decode(&resp); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if resp.OK || !strings.Contains(resp.Error, "não informado") {
		t.Fatalf("unexpected resp: %#v", resp)
	}
}

func TestHandlePairPhoneMethodNotAllowed(t *testing.T) {
	bridge := &Bridge{}
	recorder := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodDelete, "/pair-phone", nil)
	bridge.handlePairPhone(recorder, req)

	if recorder.Code != http.StatusMethodNotAllowed {
		t.Fatalf("status = %d, want %d", recorder.Code, http.StatusMethodNotAllowed)
	}
}

