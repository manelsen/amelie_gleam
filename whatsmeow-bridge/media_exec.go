package main

import (
	"context"
	"fmt"
	osExec "os/exec"
	"regexp"
	"strconv"
	"time"
)

// Limites para decodificar figurinhas animadas enviadas por terceiros.
// A conversão roda fora do handler de eventos do whatsmeow; sem esses tetos,
// uma única figurinha podia segurar o recebimento de mensagens de todos.
const (
	// Orçamento total de uma conversão (MP4 e, se falhar, grade de quadros).
	stickerConversionTimeout = 20 * time.Second
	// Figurinhas do WhatsApp têm poucos segundos; 300 quadros cobre 10 s a 30 fps.
	maxStickerDecodeFrames = 300
	// Figurinhas do WhatsApp são 512x512; 1024x1024 deixa folga sem abrir bomba.
	maxStickerCanvasPixels = 1024 * 1024
	// Conversões simultâneas. Excedente vira figurinha estática.
	maxConcurrentStickerConversions = 2
	// Tempo para o processo externo liberar os pipes depois de morto.
	mediaCommandWaitDelay = 2 * time.Second
)

var stickerConversionSlots = make(chan struct{}, maxConcurrentStickerConversions)

// tryAcquireStickerSlot reserva uma vaga de conversão sem bloquear.
// Retorna false quando todas as vagas estão ocupadas.
func tryAcquireStickerSlot() bool {
	select {
	case stickerConversionSlots <- struct{}{}:
		return true
	default:
		return false
	}
}

// releaseStickerSlot devolve a vaga reservada por tryAcquireStickerSlot.
func releaseStickerSlot() {
	<-stickerConversionSlots
}

// runMediaCommand executa um processo externo sobre mídia de terceiros com
// prazo. Ao estourar o prazo, o processo é morto e o erro diz isso.
func runMediaCommand(ctx context.Context, name string, args ...string) ([]byte, error) {
	cmd := osExec.CommandContext(ctx, name, args...)
	cmd.WaitDelay = mediaCommandWaitDelay
	out, err := cmd.CombinedOutput()
	if ctxErr := ctx.Err(); ctxErr != nil {
		return out, fmt.Errorf("%s excedeu o tempo limite: %w", name, ctxErr)
	}
	return out, err
}

var webpMuxCanvasPattern = regexp.MustCompile(`(?m)^\s*Canvas size:\s*(\d+)\s*x\s*(\d+)`)

// parseWebPMuxCanvasSize extrai largura e altura do canvas da saída de
// `webpmux -info`.
func parseWebPMuxCanvasSize(info string) (int, int, bool) {
	match := webpMuxCanvasPattern.FindStringSubmatch(info)
	if len(match) != 3 {
		return 0, 0, false
	}
	width, errW := strconv.Atoi(match[1])
	height, errH := strconv.Atoi(match[2])
	if errW != nil || errH != nil || width <= 0 || height <= 0 {
		return 0, 0, false
	}
	return width, height, true
}

// stickerCanvasAllowed diz se um canvas pode ser decodificado com segurança.
func stickerCanvasAllowed(width, height int) bool {
	return width > 0 && height > 0 && width <= maxStickerCanvasPixels/height
}
