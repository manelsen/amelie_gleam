package main

import (
	"log"
	"sync"
)

// O handler de eventos do whatsmeow roda de forma síncrona: enquanto ele não
// volta, nenhum outro evento é lido. O download de mídia pode levar até
// mediaTimeoutMax, então o processamento das mensagens sai do handler e vai
// para uma fila por chat. Cada chat tem no máximo um worker, o que preserva a
// ordem das mensagens da conversa; chats diferentes andam em paralelo, até
// maxConcurrentJobs ao mesmo tempo.
const (
	maxConcurrentJobs = 4
	maxQueuedPerChat  = 256
)

type chatDispatcher struct {
	mu     sync.Mutex
	queues map[string][]func()
	once   sync.Once
	slots  chan struct{}
}

// submit enfileira job no chat indicado e nunca bloqueia quem chama.
// Devolve false se a fila do chat estiver cheia e o job for descartado.
func (d *chatDispatcher) submit(chat string, job func()) bool {
	d.once.Do(func() { d.slots = make(chan struct{}, maxConcurrentJobs) })

	d.mu.Lock()
	defer d.mu.Unlock()
	if d.queues == nil {
		d.queues = make(map[string][]func())
	}
	queue, running := d.queues[chat]
	if len(queue) >= maxQueuedPerChat {
		return false
	}
	d.queues[chat] = append(queue, job)
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
		queue[0] = nil
		d.queues[chat] = queue[1:]
		d.mu.Unlock()

		d.slots <- struct{}{}
		func() {
			defer func() {
				<-d.slots
				if r := recover(); r != nil {
					log.Printf("[Despacho] Pânico ao processar mensagem do chat %s: %v", maskID(chat), r)
				}
			}()
			job()
		}()
	}
}
