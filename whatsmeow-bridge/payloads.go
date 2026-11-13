package main

// IncomingWebhook é o payload enviado ao Gleam quando uma mensagem chega.
type IncomingWebhook struct {
	ChatID    string `json:"chat_id"`
	From      string `json:"from"`
	MessageID string `json:"message_id,omitempty"`
	Text      string `json:"text"`
	Timestamp int64  `json:"ts"`
	InGroup   bool   `json:"em_grupo"`
	GroupName string `json:"nome_grupo,omitempty"`
	Legenda   string `json:"legenda,omitempty"`
	Tipo      string `json:"tipo"`
	Mime      string `json:"mime,omitempty"`
	Dados     string `json:"dados,omitempty"`
	Caminho   string `json:"caminho_temp,omitempty"`
}

// ReactRequest é o payload recebido do Gleam para enviar uma reação.
type ReactRequest struct {
	ChatID    string `json:"chat_id"`
	MessageID string `json:"message_id"`
	Sender    string `json:"sender"`
	Emoji     string `json:"emoji"`
}

// SendRequest é o payload recebido do Gleam para enviar uma mensagem.
type SendRequest struct {
	ChatID          string `json:"chat_id"`
	Text            string `json:"text"`
	QuotedMessageID string `json:"quoted_message_id,omitempty"`
	QuotedSender    string `json:"quoted_sender,omitempty"`
}

type APIError struct {
	Code      string `json:"code"`
	Message   string `json:"error"`
	Timestamp string `json:"timestamp,omitempty"`
}

type ErrorResponse struct {
	OK bool `json:"ok"`
	APIError
}

type HealthResponse struct {
	Status   string `json:"status"`
	LoggedIn bool   `json:"logged_in"`
	*APIError
}

type PairPhoneRequest struct {
	Phone string `json:"phone"`
}

type PairPhoneResponse struct {
	OK    bool   `json:"ok"`
	Code  string `json:"code,omitempty"`
	Phone string `json:"phone,omitempty"`
	Error string `json:"error,omitempty"`
}

type ResetSessionRequest struct {
	Phone string `json:"phone,omitempty"`
}

type ResetSessionResponse struct {
	OK     bool   `json:"ok"`
	Status string `json:"status"`
	Error  string `json:"error,omitempty"`
}
