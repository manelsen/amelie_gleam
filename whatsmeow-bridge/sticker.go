package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	waProto "go.mau.fi/whatsmeow/binary/proto"
	"go.mau.fi/whatsmeow/types"
)

func normalizeStickerMime(rawMime string) string {
	mime := normalizeMime(rawMime)
	if mime == "" {
		return "image/webp"
	}
	return mime
}

func stickerPromptContext(sticker *waProto.StickerMessage) string {
	context := "Esta imagem é uma figurinha/sticker do WhatsApp. Descreva o conteúdo visual e interprete o texto, a expressão, a referência cultural ou o sentido provável da figurinha no contexto de conversa."
	if sticker.GetIsAnimated() {
		context += " A figurinha é animada; examine todos os quadros disponíveis, especialmente textos ou mudanças que aparecem depois dos primeiros quadros."
	}
	if label := strings.TrimSpace(sticker.GetAccessibilityLabel()); label != "" {
		context += " Rótulo de acessibilidade informado pelo WhatsApp: " + label
	}
	return context
}

func stickerThumbnailFallback(sticker *waProto.StickerMessage) ([]byte, string, bool) {
	thumbnail := sticker.GetPngThumbnail()
	if len(thumbnail) == 0 {
		return nil, "", false
	}
	return thumbnail, "image/png", true
}

func (b *Bridge) scheduleStickerMetadataFallback(
	payload IncomingWebhook,
	sticker *waProto.StickerMessage,
	chat types.JID,
	messageID types.MessageID,
) {
	fallback := stickerMetadataFallbackPayload(payload, sticker)
	go func() {
		time.Sleep(12 * time.Second)
		if !b.takePendingMediaRetry(chat, messageID) {
			return
		}
		log.Printf("Media retry de figurinha não respondeu; enfileirando fallback textual: chat=%s mensagem=%s", maskID(chat.String()), messageID)
		if err := b.enqueueAndDeliver(fallback); err != nil {
			log.Printf("Erro ao enfileirar fallback textual de figurinha: chat=%s mensagem=%s erro=%v", maskID(chat.String()), messageID, err)
		}
	}()
}

func stickerMetadataFallbackPayload(payload IncomingWebhook, sticker *waProto.StickerMessage) IncomingWebhook {
	fallback := payload
	fallback.Tipo = "midia_indisponivel"
	fallback.Mime = ""
	fallback.Dados = ""
	fallback.Caminho = ""
	fallback.Legenda = ""
	fallback.Text = stickerMetadataFallbackText(sticker)
	return fallback
}

func stickerMetadataFallbackText(sticker *waProto.StickerMessage) string {
	parts := []string{
		"A mídia veio indisponível e não pude audiodescrever a figurinha.",
		"Se quiser que eu a descreva, reenvie como imagem, print ou arquivo.",
	}

	if label := strings.TrimSpace(sticker.GetAccessibilityLabel()); label != "" {
		parts = append(parts, "Rótulo de acessibilidade informado pelo WhatsApp: "+label+".")
	}
	if emojis := strings.TrimSpace(sticker.GetEmojis()); emojis != "" {
		parts = append(parts, "Emojis associados ao sticker: "+emojis+".")
	}
	if sticker.GetWidth() > 0 && sticker.GetHeight() > 0 {
		parts = append(parts, fmt.Sprintf("Dimensões declaradas: %dx%d.", sticker.GetWidth(), sticker.GetHeight()))
	}
	if sticker.GetIsAiSticker() {
		parts = append(parts, "O WhatsApp marcou este item como sticker gerado por IA.")
	}
	if sticker.GetIsAnimated() {
		parts = append(parts, "O WhatsApp marcou este item como sticker animado.")
	}

	return strings.Join(parts, "\n")
}

const maxAnimatedStickerFrames = 16

const animatedStickerTileSize = 320

// deliverAnimatedSticker converte e entrega uma figurinha animada fora do
// handler de eventos. Deve ser chamada com uma vaga já reservada por
// tryAcquireStickerSlot; libera a vaga ao terminar. A conversão inteira
// respeita stickerConversionTimeout. Se MP4 e grade falharem, a figurinha
// segue como WebP estático, como antes.
func (b *Bridge) deliverAnimatedSticker(payload IncomingWebhook, data []byte, chat types.JID, messageID types.MessageID) {
	defer releaseStickerSlot()
	defer b.clearMediaRetryState(chat, messageID)

	ctx, cancel := context.WithTimeout(context.Background(), stickerConversionTimeout)
	defer cancel()

	if videoPath, ok := convertAnimatedStickerToMP4(ctx, data); ok {
		payload.Tipo = "video"
		payload.Mime = "video/mp4"
		payload.Caminho = videoPath
		payload.Dados = ""
		log.Printf("Figurinha animada convertida para MP4: chat=%s mensagem=%s caminho=%s", maskID(payload.ChatID), messageID, videoPath)
	} else if sheet, sheetMime, ok := convertAnimatedStickerToContactSheet(ctx, data); ok {
		data = sheet
		payload.Mime = sheetMime
		log.Printf("Figurinha animada convertida em grade de quadros: chat=%s mensagem=%s bytes=%d", maskID(payload.ChatID), messageID, len(data))
	} else {
		log.Printf("Figurinha animada será processada como sticker WebP: chat=%s mensagem=%s", maskID(payload.ChatID), messageID)
	}

	if payload.Caminho == "" && !b.attachMediaFile(&payload, "sticker", "", data) {
		return
	}
	if err := b.enqueueAndDeliver(payload); err != nil {
		log.Printf("Erro ao enfileirar figurinha animada: chat=%s mensagem=%s erro=%v", maskID(payload.ChatID), messageID, err)
	}
}

// convertAnimatedStickerToMP4 converte uma figurinha WebP animada em MP4 no
// spool privado. Todo processo externo respeita o prazo de ctx, e o script
// recusa formato que não seja WebP, canvas grande demais e quadros demais.
func convertAnimatedStickerToMP4(ctx context.Context, data []byte) (string, bool) {
	dir, err := os.MkdirTemp("", "amelie_sticker_anim_*")
	if err != nil {
		log.Printf("Falha ao criar diretório temporário para vídeo de figurinha animada: %v", err)
		return "", false
	}
	defer os.RemoveAll(dir)

	inputPath := filepath.Join(dir, "input.webp")
	if err := os.WriteFile(inputPath, data, 0o600); err != nil {
		log.Printf("Falha ao escrever figurinha animada temporária: %v", err)
		return "", false
	}

	scriptPath := filepath.Join(dir, "decode_webp_animation.py")
	if err := os.WriteFile(scriptPath, []byte(animatedWebPToFramesScript), 0o600); err != nil {
		log.Printf("Falha ao escrever decoder de figurinha animada: %v", err)
		return "", false
	}

	framesDir := filepath.Join(dir, "frames")
	out, err := runMediaCommand(
		ctx,
		"python3", "-I", scriptPath, inputPath, framesDir,
		strconv.Itoa(maxStickerDecodeFrames),
		strconv.Itoa(maxStickerCanvasPixels),
	)
	if err != nil {
		log.Printf("Falha ao decodificar ANIM/ANMF da figurinha: erro=%v saida=%s", err, strings.TrimSpace(string(out)))
		return "", false
	}

	mediaDir, err := mediaTempDir()
	if err != nil {
		return "", false
	}
	output, err := os.CreateTemp(mediaDir, mediaTempPrefix+"sticker_*.mp4")
	if err != nil {
		log.Printf("Falha ao criar MP4 temporário de figurinha animada: %v", err)
		return "", false
	}
	outputPath := output.Name()
	output.Close()

	out, err = runMediaCommand(
		ctx,
		"ffmpeg",
		"-y",
		"-hide_banner",
		"-loglevel", "error",
		"-f", "concat",
		"-safe", "0",
		"-i", filepath.Join(framesDir, "frames.txt"),
		"-c:v", "libx264",
		"-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2,format=yuv420p",
		"-movflags", "+faststart",
		outputPath,
	)
	if err != nil {
		os.Remove(outputPath)
		log.Printf("Falha ao converter figurinha animada para MP4: erro=%v saida=%s", err, strings.TrimSpace(string(out)))
		return "", false
	}

	info, err := os.Stat(outputPath)
	if err != nil || info.Size() == 0 {
		os.Remove(outputPath)
		log.Printf("Conversão de figurinha animada gerou MP4 inválido: erro=%v", err)
		return "", false
	}

	return outputPath, true
}

// convertAnimatedStickerToContactSheet monta uma grade PNG com até
// maxAnimatedStickerFrames quadros da figurinha. Todo processo externo
// respeita o prazo de ctx, e canvas acima do limite é recusado antes de
// qualquer decodificação.
func convertAnimatedStickerToContactSheet(ctx context.Context, data []byte) ([]byte, string, bool) {
	dir, err := os.MkdirTemp("", "amelie_sticker_frames_*")
	if err != nil {
		log.Printf("Falha ao criar diretório temporário para figurinha animada: %v", err)
		return nil, "", false
	}
	defer os.RemoveAll(dir)

	inputPath := filepath.Join(dir, "input.webp")
	if err := os.WriteFile(inputPath, data, 0o600); err != nil {
		log.Printf("Falha ao escrever figurinha animada temporária: %v", err)
		return nil, "", false
	}

	infoOut, err := runMediaCommand(ctx, "webpmux", "-info", inputPath)
	if err != nil {
		log.Printf("Falha ao inspecionar figurinha animada com webpmux: erro=%v saida=%s", err, strings.TrimSpace(string(infoOut)))
		return nil, "", false
	}
	width, height, ok := parseWebPMuxCanvasSize(string(infoOut))
	if !ok || !stickerCanvasAllowed(width, height) {
		log.Printf("Figurinha animada recusada: canvas %dx%d fora do limite", width, height)
		return nil, "", false
	}
	frameCount, ok := parseWebPMuxFrameCount(string(infoOut))
	if !ok || frameCount < 2 {
		log.Printf("Figurinha marcada como animada sem contagem de quadros útil: frames=%d", frameCount)
		return nil, "", false
	}

	indices := sampleFrameIndices(frameCount, maxAnimatedStickerFrames)
	for pos, frameIndex := range indices {
		webpPath := filepath.Join(dir, fmt.Sprintf("frame_%03d.webp", pos+1))
		pngPath := filepath.Join(dir, fmt.Sprintf("frame_%03d.png", pos+1))

		out, err := runMediaCommand(ctx, "webpmux", "-get", "frame", strconv.Itoa(frameIndex), inputPath, "-o", webpPath)
		if err != nil {
			log.Printf("Falha ao extrair quadro %d/%d da figurinha: erro=%v saida=%s", frameIndex, frameCount, err, strings.TrimSpace(string(out)))
			return nil, "", false
		}

		out, err = runMediaCommand(ctx, "dwebp", "-quiet", webpPath, "-o", pngPath)
		if err != nil {
			log.Printf("Falha ao converter quadro %d da figurinha para PNG: erro=%v saida=%s", frameIndex, err, strings.TrimSpace(string(out)))
			return nil, "", false
		}
	}

	cols, rows := contactSheetGrid(len(indices))
	outputPath := filepath.Join(dir, "sheet.png")
	filter := fmt.Sprintf(
		"scale=%d:%d:force_original_aspect_ratio=decrease,pad=%d:%d:(ow-iw)/2:(oh-ih)/2:color=white,tile=%dx%d:padding=8:margin=8:color=white",
		animatedStickerTileSize,
		animatedStickerTileSize,
		animatedStickerTileSize,
		animatedStickerTileSize,
		cols,
		rows,
	)
	out, err := runMediaCommand(
		ctx,
		"ffmpeg",
		"-y",
		"-hide_banner",
		"-loglevel", "error",
		"-framerate", "1",
		"-i", filepath.Join(dir, "frame_%03d.png"),
		"-frames:v", "1",
		"-vf", filter,
		outputPath,
	)
	if err != nil {
		log.Printf("Falha ao montar grade de quadros da figurinha: erro=%v saida=%s", err, strings.TrimSpace(string(out)))
		return nil, "", false
	}

	sheet, err := os.ReadFile(outputPath)
	if err != nil || len(sheet) == 0 {
		log.Printf("Grade de quadros da figurinha inválida: erro=%v bytes=%d", err, len(sheet))
		return nil, "", false
	}
	return sheet, "image/png", true
}

func parseWebPMuxFrameCount(info string) (int, bool) {
	for _, line := range strings.Split(info, "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "Number of frames:") {
			value := strings.TrimSpace(strings.TrimPrefix(line, "Number of frames:"))
			count, err := strconv.Atoi(value)
			return count, err == nil
		}
	}
	return 0, false
}

func sampleFrameIndices(frameCount int, maxFrames int) []int {
	if frameCount <= 0 || maxFrames <= 0 {
		return []int{}
	}
	if frameCount <= maxFrames {
		indices := make([]int, frameCount)
		for i := range indices {
			indices[i] = i + 1
		}
		return indices
	}

	indices := make([]int, 0, maxFrames)
	last := 0
	for i := 0; i < maxFrames; i++ {
		index := 1 + (i*(frameCount-1)+(maxFrames-1)/2)/(maxFrames-1)
		if index != last {
			indices = append(indices, index)
			last = index
		}
	}
	return indices
}

func contactSheetGrid(frameCount int) (int, int) {
	if frameCount <= 1 {
		return 1, 1
	}
	cols := 4
	if frameCount < cols {
		cols = frameCount
	}
	rows := (frameCount + cols - 1) / cols
	return cols, rows
}
