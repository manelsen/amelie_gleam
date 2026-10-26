package main

import (
	"sync"
	"time"
)

// groupNameTTL é por quanto tempo o nome de um grupo fica em cache. Renomear
// um grupo é raro; consultar o WhatsApp a cada mensagem seria desperdício.
const groupNameTTL = time.Hour

type cachedGroupName struct {
	name    string
	expires time.Time
}

// groupNameCache guarda o nome de cada grupo por chat. Antes, a ponte usava
// o PushName do remetente (o nome de exibição de uma pessoa) como nome do
// grupo, e esse dado pessoal ia parar na tabela de grupos.
type groupNameCache struct {
	mu      sync.Mutex
	entries map[string]cachedGroupName
	now     func() time.Time
}

func newGroupNameCache() *groupNameCache {
	return &groupNameCache{entries: map[string]cachedGroupName{}, now: time.Now}
}

// get devolve o nome em cache, buscando com fetch quando ausente ou vencido.
// Em erro de busca, devolve "" (o Gleam usa "Grupo") e não guarda nada, para
// tentar de novo na próxima mensagem.
func (c *groupNameCache) get(chatID string, fetch func() (string, error)) string {
	c.mu.Lock()
	entry, ok := c.entries[chatID]
	c.mu.Unlock()
	if ok && c.now().Before(entry.expires) {
		return entry.name
	}
	name, err := fetch()
	if err != nil {
		return ""
	}
	c.mu.Lock()
	c.entries[chatID] = cachedGroupName{name: name, expires: c.now().Add(groupNameTTL)}
	c.mu.Unlock()
	return name
}
