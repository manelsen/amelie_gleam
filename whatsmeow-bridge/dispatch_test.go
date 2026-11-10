package main

import (
	"sync"
	"testing"
	"time"
)

// Um job lento num chat não pode segurar quem enfileira nem os outros chats.
func TestDispatcherNaoBloqueiaOutrosChats(t *testing.T) {
	var d chatDispatcher
	liberar := make(chan struct{})
	outro := make(chan struct{})

	inicio := time.Now()
	d.submit("lento", "", func() { <-liberar })
	d.submit("rapido", "", func() { close(outro) })
	if time.Since(inicio) > 100*time.Millisecond {
		t.Fatal("submit bloqueou quem chamou")
	}

	select {
	case <-outro:
	case <-time.After(2 * time.Second):
		t.Fatal("chat rápido ficou preso atrás do chat lento")
	}
	close(liberar)
}

// As mensagens de um mesmo chat saem na ordem em que chegaram, uma de cada vez.
func TestDispatcherPreservaOrdemPorChat(t *testing.T) {
	var d chatDispatcher
	var mu sync.Mutex
	var ordem []int
	ativos, maxAtivos := 0, 0
	var wg sync.WaitGroup

	for i := 0; i < 50; i++ {
		wg.Add(1)
		i := i
		d.submit("chat", "", func() {
			defer wg.Done()
			mu.Lock()
			ativos++
			if ativos > maxAtivos {
				maxAtivos = ativos
			}
			ordem = append(ordem, i)
			mu.Unlock()
			time.Sleep(time.Millisecond)
			mu.Lock()
			ativos--
			mu.Unlock()
		})
	}
	wg.Wait()

	if maxAtivos != 1 {
		t.Fatalf("chat teve %d jobs simultâneos", maxAtivos)
	}
	for i, v := range ordem {
		if v != i {
			t.Fatalf("ordem trocada: %v", ordem)
		}
	}
}

// Nunca passam de maxConcurrentDownloads downloads ao mesmo tempo.
func TestLimiteGlobalDeDownloads(t *testing.T) {
	var mu sync.Mutex
	ativos, maxAtivos := 0, 0
	var wg sync.WaitGroup

	for i := 0; i < maxConcurrentDownloads*3; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			withMediaDownloadSlot(func() struct{} {
				mu.Lock()
				ativos++
				if ativos > maxAtivos {
					maxAtivos = ativos
				}
				mu.Unlock()
				time.Sleep(20 * time.Millisecond)
				mu.Lock()
				ativos--
				mu.Unlock()
				return struct{}{}
			})
		}()
	}
	wg.Wait()

	if maxAtivos > maxConcurrentDownloads {
		t.Fatalf("%d downloads simultâneos, limite %d", maxAtivos, maxConcurrentDownloads)
	}
}

// Downloads lentos ocupando todas as vagas não seguram texto de outro chat.
func TestDispatcherTextoNaoEsperaDownloads(t *testing.T) {
	var d chatDispatcher
	liberar := make(chan struct{})
	ocupados := make(chan struct{}, maxConcurrentDownloads+2)
	for i := 0; i < maxConcurrentDownloads+2; i++ {
		d.submit(string(rune('a'+i)), "", func() {
			withMediaDownloadSlot(func() struct{} {
				ocupados <- struct{}{}
				<-liberar
				return struct{}{}
			})
		})
	}
	for i := 0; i < maxConcurrentDownloads; i++ {
		<-ocupados
	}

	texto := make(chan struct{})
	d.submit("texto", "", func() { close(texto) })
	select {
	case <-texto:
	case <-time.After(2 * time.Second):
		t.Fatal("texto ficou esperando vaga de download")
	}
	close(liberar)
}

// Worker sai quando a fila esvazia, e um job novo no mesmo chat ainda roda.
func TestDispatcherReativaChatOcioso(t *testing.T) {
	var d chatDispatcher
	feito := make(chan struct{}, 2)
	d.submit("chat", "", func() { feito <- struct{}{} })
	<-feito

	prazo := time.Now().Add(2 * time.Second)
	for {
		d.mu.Lock()
		_, vivo := d.queues["chat"]
		d.mu.Unlock()
		if !vivo {
			break
		}
		if time.Now().After(prazo) {
			t.Fatal("worker ocioso não saiu")
		}
		time.Sleep(time.Millisecond)
	}

	d.submit("chat", "", func() { feito <- struct{}{} })
	select {
	case <-feito:
	case <-time.After(2 * time.Second):
		t.Fatal("job enfileirado após o worker sair não rodou")
	}
}

// Fila cheia descarta em vez de bloquear.
func TestDispatcherFilaCheia(t *testing.T) {
	var d chatDispatcher
	liberar := make(chan struct{})
	d.submit("chat", "", func() { <-liberar })
	defer close(liberar)

	// O primeiro job pode ainda estar na fila ou já em execução.
	aceitos := 0
	for i := 0; i < maxQueuedPerChat+1; i++ {
		if d.submit("chat", "", func() {}) {
			aceitos++
		}
	}
	if aceitos > maxQueuedPerChat {
		t.Fatalf("aceitou %d jobs, limite %d", aceitos, maxQueuedPerChat)
	}
	if d.submit("chat", "", func() {}) {
		t.Fatal("fila cheia aceitou mais um job")
	}
}
