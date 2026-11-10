package main

import (
	"log"
	"sync"
)

// O handler de eventos do whatsmeow roda de forma síncrona: enquanto ele não
// volta, nenhum outro evento é lido. O download de mídia pode levar até
// mediaTimeoutMax, então o processamento das mensagens sai do handler e vai
// para uma fila por chat. Cada chat tem no máximo um worker, o que preserva a
// ordem das mensagens da conversa; chats diferentes andam em paralelo.
//
// A ordem é de melhor esforço: uma mídia que precisou de media retry volta
// para o fim da fila do chat quando o reenvio chega, depois de mensagens que
// chegaram nesse meio-tempo.
//
// O que é limitado globalmente são os downloads (mediaDownloadSlots), não os
// jobs: texto de um chat não espera vídeo de outro.
const (
	maxConcurrentDownloads = 4
	maxQueuedPerChat       = 256
)

var mediaDownloadSlots = make(chan struct{}, maxConcurrentDownloads)

// withMediaDownloadSlot espera uma vaga de download e roda fn com ela. O
// prazo do download deve ser criado dentro de fn, para a espera não comê-lo.
func withMediaDownloadSlot[T any](fn func() T) T {
	mediaDownloadSlots <- struct{}{}
	defer func() { <-mediaDownloadSlots }()
	return fn()
}

type dispatchJob struct {
	id  string
	run func()
}

type chatDispatcher struct {
	mu     sync.Mutex
	queues map[string][]dispatchJob
}

// submit enfileira job no chat indicado e nunca bloqueia quem chama. id só
// identifica a mensagem nos logs. Devolve false se a fila do chat estiver
// cheia e o job for descartado.
func (d *chatDispatcher) submit(chat, id string, job func()) bool {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.queues == nil {
		d.queues = make(map[string][]dispatchJob)
	}
	queue, running := d.queues[chat]
	if len(queue) >= maxQueuedPerChat {
		return false
	}
	d.queues[chat] = append(queue, dispatchJob{id: id, run: job})
	if !running {
		go d.run(chat)
	}
	return true
}

// run executa os jobs do chat em ordem e sai quando a fila esvazia. A entrada
// do chat no mapa existe enquanto o worker está vivo; é ela que impede um
// segundo worker para o mesmo chat.
func (d *chatDispatcher) run(chat string) {
	for {
		d.mu.Lock()
		queue := d.queues[chat]
		if len(queue) == 0 {
			delete(d.queues, chat)
			d.mu.Unlock()
			return
		}
		job := queue[0]
		queue[0] = dispatchJob{}
		d.queues[chat] = queue[1:]
		d.mu.Unlock()

		func() {
			defer func() {
				if r := recover(); r != nil {
					log.Printf("[Despacho] Pânico ao processar mensagem %s do chat %s: %v", job.id, maskID(chat), r)
				}
			}()
			job.run()
		}()
	}
}
