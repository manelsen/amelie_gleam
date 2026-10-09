package main

import (
	"bytes"
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"os"
	"path/filepath"
	"time"
)

const bridgeTokenHeader = "X-Amelie-Bridge-Token"
const maxFetchedBytes = 1024 * 1024

// A ausência de segredo nunca habilita acesso anônimo.
func (b *Bridge) authenticated(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		token := r.Header.Get(bridgeTokenHeader)
		if len(b.cfg.Token) < 32 || subtle.ConstantTimeCompare([]byte(token), []byte(b.cfg.Token)) != 1 {
			writeAPIError(w, http.StatusUnauthorized, APIError{Code: "unauthorized", Message: "autenticação necessária"})
			return
		}
		r.Body = http.MaxBytesReader(w, r.Body, 1024*1024)
		next.ServeHTTP(w, r)
	})
}

func (b *Bridge) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/send", b.handleSend)
	mux.HandleFunc("/react", b.handleReact)
	mux.HandleFunc("/health", b.handleHealth)
	mux.HandleFunc("/pair-phone", b.handlePairPhone)
	mux.HandleFunc("/reset-session", b.handleResetSession)
	mux.HandleFunc("/fetch", b.handleFetch)
	return b.authenticated(mux)
}

func (b *Bridge) postAuthenticated(endpoint string, data []byte) (*http.Response, error) {
	if len(b.cfg.Token) < 32 {
		return nil, errors.New("BRIDGE_TOKEN ausente ou muito curto")
	}
	req, err := http.NewRequest(http.MethodPost, endpoint, bytes.NewReader(data))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set(bridgeTokenHeader, b.cfg.Token)
	return httpClient.Do(req)
}

// Só arquivos gerados pelo bridge entram neste diretório privado.
func mediaTempDir() (string, error) {
	dir := getEnv("MEDIA_TEMP_DIR", "/tmp/amelie-media")
	if !filepath.IsAbs(dir) || filepath.Clean(dir) != dir {
		return "", errors.New("MEDIA_TEMP_DIR deve ser um caminho absoluto normalizado")
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", err
	}
	info, err := os.Lstat(dir)
	if err != nil {
		return "", err
	}
	if !info.IsDir() || info.Mode().Perm() != 0o700 {
		return "", errors.New("MEDIA_TEMP_DIR deve ser um diretório privado (0700), sem symlink")
	}
	return dir, nil
}

var blockedNetworks = []netip.Prefix{
	netip.MustParsePrefix("0.0.0.0/8"), netip.MustParsePrefix("100.64.0.0/10"),
	netip.MustParsePrefix("192.0.0.0/24"), netip.MustParsePrefix("192.0.2.0/24"),
	netip.MustParsePrefix("192.88.99.0/24"), netip.MustParsePrefix("198.18.0.0/15"),
	netip.MustParsePrefix("198.51.100.0/24"), netip.MustParsePrefix("203.0.113.0/24"),
	netip.MustParsePrefix("240.0.0.0/4"), netip.MustParsePrefix("2001::/23"),
	netip.MustParsePrefix("2001:db8::/32"), netip.MustParsePrefix("2002::/16"),
}

func publicAddress(ip netip.Addr) bool {
	ip = ip.Unmap()
	if !ip.IsGlobalUnicast() || ip.IsPrivate() || ip.IsLinkLocalUnicast() || ip.IsLoopback() {
		return false
	}
	// Exclui também NAT64, endereços locais e mecanismos de transição.
	if ip.Is6() && !netip.MustParsePrefix("2000::/3").Contains(ip) {
		return false
	}
	for _, prefix := range blockedNetworks {
		if prefix.Contains(ip) {
			return false
		}
	}
	return true
}

type publicDialer struct {
	lookup func(context.Context, string, string) ([]netip.Addr, error)
	dial   func(context.Context, string, string) (net.Conn, error)
}

func (d publicDialer) DialContext(ctx context.Context, network, address string) (net.Conn, error) {
	host, port, err := net.SplitHostPort(address)
	if err != nil || (port != "80" && port != "443") {
		return nil, errors.New("destino não permitido")
	}
	ips, err := d.lookup(ctx, "ip", host)
	if err != nil || len(ips) == 0 {
		return nil, errors.New("não foi possível resolver o destino")
	}
	for _, ip := range ips {
		if !publicAddress(ip) {
			return nil, errors.New("endereços internos ou reservados não são permitidos")
		}
	}
	// Conecta ao IP já validado. Nunca resolve o hostname uma segunda vez.
	return d.dial(ctx, network, net.JoinHostPort(ips[0].Unmap().String(), port))
}

func validateFetchURL(u *url.URL) error {
	if u == nil || u.Hostname() == "" || u.User != nil || u.Opaque != "" {
		return errors.New("URL inválida")
	}
	if u.Scheme != "http" && u.Scheme != "https" {
		return errors.New("somente HTTP e HTTPS são permitidos")
	}
	if port := u.Port(); port != "" && !((u.Scheme == "http" && port == "80") || (u.Scheme == "https" && port == "443")) {
		return errors.New("porta não permitida")
	}
	return nil
}

func newPublicHTTPClient() *http.Client {
	dialer := publicDialer{net.DefaultResolver.LookupNetIP, (&net.Dialer{Timeout: 5 * time.Second}).DialContext}
	return &http.Client{
		Timeout: 15 * time.Second,
		Transport: &http.Transport{
			Proxy: nil, DialContext: dialer.DialContext,
			TLSHandshakeTimeout: 5 * time.Second, ResponseHeaderTimeout: 10 * time.Second,
			MaxResponseHeaderBytes: 32 * 1024, DisableKeepAlives: true,
		},
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			if len(via) >= 3 {
				return errors.New("limite de redirecionamentos excedido")
			}
			return validateFetchURL(req.URL)
		},
	}
}

var publicHTTPClient = newPublicHTTPClient()

func fetchPublic(ctx context.Context, client *http.Client, rawURL string) ([]byte, error) {
	u, err := url.Parse(rawURL)
	if err != nil {
		return nil, errors.New("URL inválida")
	}
	if err := validateFetchURL(u); err != nil {
		return nil, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u.String(), nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", "AmelieBot/2.0")
	req.Header.Set("Accept", "text/html,application/xhtml+xml,text/plain")
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("destino retornou status %d", resp.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, maxFetchedBytes+1))
	if err != nil {
		return nil, err
	}
	if len(body) > maxFetchedBytes {
		return nil, errors.New("página excede o limite de 1 MiB")
	}
	return body, nil
}

func (b *Bridge) handleFetch(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	var input struct {
		URL string `json:"url"`
	}
	if json.NewDecoder(r.Body).Decode(&input) != nil {
		writeAPIError(w, http.StatusBadRequest, APIError{Code: "invalid_json", Message: "URL inválida"})
		return
	}
	body, err := fetchPublic(r.Context(), publicHTTPClient, input.URL)
	if err != nil {
		// Não devolve conteúdo ou detalhes de endereços internos ao solicitante.
		writeAPIError(w, http.StatusBadGateway, APIError{Code: "fetch_failed", Message: "não foi possível buscar a página pública"})
		return
	}
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	_, _ = w.Write(body)
}
