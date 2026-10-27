package main

import (
	"bytes"
	"context"
	"image"
	"image/color"
	"image/gif"
	"os"
	osExec "os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

func TestRunMediaCommandKillsOnTimeout(t *testing.T) {
	if _, err := osExec.LookPath("sleep"); err != nil {
		t.Skip("sleep indisponível")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()

	start := time.Now()
	_, err := runMediaCommand(ctx, "sleep", "30")
	elapsed := time.Since(start)

	if err == nil || !strings.Contains(err.Error(), "tempo limite") {
		t.Fatalf("esperava erro de tempo limite, veio %v", err)
	}
	if elapsed > 5*time.Second {
		t.Fatalf("processo não foi interrompido a tempo: %v", elapsed)
	}
}

func TestStickerConversionSlotsAreBounded(t *testing.T) {
	for i := 0; i < maxConcurrentStickerConversions; i++ {
		if !tryAcquireStickerSlot() {
			t.Fatalf("vaga %d deveria estar livre", i+1)
		}
	}
	if tryAcquireStickerSlot() {
		t.Fatal("aceitou conversão acima do limite")
	}
	releaseStickerSlot()
	if !tryAcquireStickerSlot() {
		t.Fatal("vaga liberada não voltou a ficar disponível")
	}
	for i := 0; i < maxConcurrentStickerConversions; i++ {
		releaseStickerSlot()
	}
}

func TestParseWebPMuxCanvasSize(t *testing.T) {
	info := "Canvas size: 512 x 512\nFeatures present: animation\nNumber of frames: 12\n"
	w, h, ok := parseWebPMuxCanvasSize(info)
	if !ok || w != 512 || h != 512 {
		t.Fatalf("esperava 512x512, veio %dx%d ok=%v", w, h, ok)
	}
	if _, _, ok := parseWebPMuxCanvasSize("Number of frames: 12\n"); ok {
		t.Fatal("aceitou saída sem canvas")
	}
}

func TestStickerCanvasAllowed(t *testing.T) {
	cases := []struct {
		w, h int
		want bool
	}{
		{512, 512, true},
		{1024, 1024, true},
		{1025, 1024, false},
		{16383, 16383, false},
		{0, 512, false},
		{1 << 30, 1 << 30, false},
	}
	for _, c := range cases {
		if got := stickerCanvasAllowed(c.w, c.h); got != c.want {
			t.Fatalf("%dx%d: esperava %v, veio %v", c.w, c.h, c.want, got)
		}
	}
}

// requirePillow pula o teste quando o ambiente não tem python3 com Pillow.
func requirePillow(t *testing.T) {
	t.Helper()
	if err := osExec.Command("python3", "-I", "-c", "import PIL").Run(); err != nil {
		t.Skip("python3 com Pillow indisponível")
	}
}

// writeAnimatedWebP gera uma figurinha WebP animada com o próprio Pillow.
func writeAnimatedWebP(t *testing.T, path string, frames, width, height int) {
	t.Helper()
	script := `import sys
from PIL import Image
path, n, w, h = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
imgs = [Image.new("RGBA", (w, h), ((i * 37) % 256, (i * 91) % 256, (i * 53) % 256, 255)) for i in range(n)]
imgs[0].save(path, format="WEBP", save_all=True, append_images=imgs[1:], duration=50, loop=0, lossless=True, minimize_size=False, allow_mixed=False)
`
	out, err := osExec.Command("python3", "-I", "-c", script, path,
		strconv.Itoa(frames), strconv.Itoa(width), strconv.Itoa(height)).CombinedOutput()
	if err != nil {
		t.Skipf("Pillow sem suporte a WebP animado: %v %s", err, out)
	}
}

func runDecoderScript(t *testing.T, input string) ([]byte, error) {
	t.Helper()
	dir := t.TempDir()
	scriptPath := filepath.Join(dir, "decode.py")
	if err := os.WriteFile(scriptPath, []byte(animatedWebPToFramesScript), 0o600); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), stickerConversionTimeout)
	defer cancel()
	return runMediaCommand(ctx, "python3", "-I", scriptPath, input, filepath.Join(dir, "frames"),
		strconv.Itoa(maxStickerDecodeFrames), strconv.Itoa(maxStickerCanvasPixels))
}

func TestDecoderScriptRejectsNonWebP(t *testing.T) {
	requirePillow(t)
	// GIF animado com extensão .webp: antes, o Pillow abria pelo conteúdo.
	palette := color.Palette{color.Black, color.White}
	anim := &gif.GIF{}
	for i := 0; i < 3; i++ {
		anim.Image = append(anim.Image, image.NewPaletted(image.Rect(0, 0, 8, 8), palette))
		anim.Delay = append(anim.Delay, 10)
	}
	var buf bytes.Buffer
	if err := gif.EncodeAll(&buf, anim); err != nil {
		t.Fatal(err)
	}
	input := filepath.Join(t.TempDir(), "input.webp")
	if err := os.WriteFile(input, buf.Bytes(), 0o600); err != nil {
		t.Fatal(err)
	}
	if out, err := runDecoderScript(t, input); err == nil {
		t.Fatalf("script aceitou GIF disfarçado de WebP: %s", out)
	}
}

func TestDecoderScriptRejectsTooManyFrames(t *testing.T) {
	requirePillow(t)
	input := filepath.Join(t.TempDir(), "input.webp")
	writeAnimatedWebP(t, input, maxStickerDecodeFrames+1, 16, 16)
	out, err := runDecoderScript(t, input)
	if err == nil || !strings.Contains(string(out), "quadros demais") {
		t.Fatalf("esperava recusa por quadros demais, veio err=%v saida=%s", err, out)
	}
}

func TestDecoderScriptRejectsLargeCanvas(t *testing.T) {
	requirePillow(t)
	input := filepath.Join(t.TempDir(), "input.webp")
	writeAnimatedWebP(t, input, 2, 2048, 1024)
	out, err := runDecoderScript(t, input)
	if err == nil {
		t.Fatalf("script aceitou canvas acima do limite: %s", out)
	}
}

func TestDecoderScriptAcceptsRegularSticker(t *testing.T) {
	requirePillow(t)
	input := filepath.Join(t.TempDir(), "input.webp")
	writeAnimatedWebP(t, input, 12, 512, 512)
	out, err := runDecoderScript(t, input)
	if err != nil {
		t.Fatalf("figurinha comum recusada: %v %s", err, out)
	}
	if !strings.Contains(string(out), "frames=12") {
		t.Fatalf("esperava 12 quadros, saída: %s", out)
	}
}
