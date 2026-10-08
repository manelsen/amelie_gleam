package main

import (
	"context"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const testBridgeToken = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

func TestBridgeRoutesRejectMissingAndIncorrectTokens(t *testing.T) {
	for _, path := range []string{"/send", "/react", "/health", "/pair-phone", "/reset-session", "/fetch"} {
		for _, token := range []string{"", "wrong"} {
			t.Run(path+token, func(t *testing.T) {
				bridge := &Bridge{cfg: Config{Token: testBridgeToken}}
				req := httptest.NewRequest(http.MethodPost, path, strings.NewReader("{}"))
				req.Header.Set(bridgeTokenHeader, token)
				rec := httptest.NewRecorder()
				bridge.routes().ServeHTTP(rec, req)
				if rec.Code != http.StatusUnauthorized {
					t.Fatalf("status=%d, want 401", rec.Code)
				}
			})
		}
	}
}

func TestEmptyConfiguredSecretDoesNotAllowAccess(t *testing.T) {
	bridge := &Bridge{}
	rec := httptest.NewRecorder()
	bridge.routes().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/health", nil))
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status=%d", rec.Code)
	}
}

func TestAuthenticatedHealthAndPairingMethod(t *testing.T) {
	bridge := &Bridge{cfg: Config{Token: testBridgeToken}}
	for _, test := range []struct {
		path   string
		status int
	}{
		{"/health", http.StatusServiceUnavailable}, {"/pair-phone?phone=123", http.StatusMethodNotAllowed},
	} {
		req := httptest.NewRequest(http.MethodGet, test.path, nil)
		req.Header.Set(bridgeTokenHeader, testBridgeToken)
		rec := httptest.NewRecorder()
		bridge.routes().ServeHTTP(rec, req)
		if rec.Code != test.status {
			t.Fatalf("%s: status=%d, want %d", test.path, rec.Code, test.status)
		}
	}
}

func TestOutgoingWebhookAuthenticationAndNoRedirect(t *testing.T) {
	targetCalls := 0
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { targetCalls++ }))
	defer target.Close()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get(bridgeTokenHeader) != testBridgeToken {
			t.Error("webhook sem autenticação")
		}
		w.Header().Set("Location", target.URL)
		w.WriteHeader(http.StatusTemporaryRedirect)
	}))
	defer server.Close()
	b := &Bridge{cfg: Config{Token: testBridgeToken, GleamURL: server.URL}}
	if err := b.postToGleam(IncomingWebhook{}); err == nil {
		t.Fatal("redirecionamento tratado como sucesso")
	}
	if targetCalls != 0 {
		t.Fatal("segredo encaminhado em redirecionamento")
	}
}

func TestPublicAddressPolicy(t *testing.T) {
	for _, ip := range []string{"127.0.0.1", "10.0.0.1", "172.16.0.1", "192.168.1.1", "169.254.169.254", "100.64.1.1", "0.0.0.0", "192.0.0.1", "198.18.0.1", "203.0.113.1", "224.0.0.1", "240.0.0.1", "::", "::1", "fc00::1", "fe80::1", "::ffff:127.0.0.1", "64:ff9b::7f00:1", "2001:db8::1", "2002:7f00:1::"} {
		if publicAddress(netip.MustParseAddr(ip)) {
			t.Errorf("endereço reservado aceito: %s", ip)
		}
	}
	for _, ip := range []string{"93.184.216.34", "2606:4700:4700::1111"} {
		if !publicAddress(netip.MustParseAddr(ip)) {
			t.Errorf("endereço público rejeitado: %s", ip)
		}
	}
}

func TestDialPinsValidatedIPAndRejectsMixedDNS(t *testing.T) {
	for _, mixed := range []bool{false, true} {
		lookups, dials := 0, 0
		d := publicDialer{
			lookup: func(context.Context, string, string) ([]netip.Addr, error) {
				lookups++
				ips := []netip.Addr{netip.MustParseAddr("93.184.216.34")}
				if mixed {
					ips = append(ips, netip.MustParseAddr("127.0.0.1"))
				}
				return ips, nil
			},
			dial: func(_ context.Context, _, address string) (net.Conn, error) {
				dials++
				if address != "93.184.216.34:443" {
					t.Errorf("segunda resolução possível: %s", address)
				}
				return nil, errors.New("fim da simulação")
			},
		}
		_, _ = d.DialContext(context.Background(), "tcp", "public.example:443")
		if lookups != 1 || (!mixed && dials != 1) || (mixed && dials != 0) {
			t.Fatalf("mixed=%v lookups=%d dials=%d", mixed, lookups, dials)
		}
	}
}

func TestFetchRejectsUnsafeURLWithoutNetwork(t *testing.T) {
	for _, raw := range []string{"file:///etc/passwd", "ftp://example.com", "http://user:pass@example.com", "http://127.0.0.1", "http://[::1]", "http://169.254.169.254", "http://public.example:8080"} {
		if _, err := fetchPublic(context.Background(), newPublicHTTPClient(), raw); err == nil {
			t.Errorf("URL aceita: %s", raw)
		}
	}
}

func TestFetchRedirectCannotReachPrivateIP(t *testing.T) {
	requests := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests++
		http.Redirect(w, r, "http://127.0.0.1/private", http.StatusFound)
	}))
	defer server.Close()
	d := publicDialer{
		lookup: func(_ context.Context, _, host string) ([]netip.Addr, error) {
			if host == "public.example" {
				return []netip.Addr{netip.MustParseAddr("93.184.216.34")}, nil
			}
			return []netip.Addr{netip.MustParseAddr("127.0.0.1")}, nil
		},
		dial: func(ctx context.Context, network, address string) (net.Conn, error) {
			if address != "93.184.216.34:80" {
				t.Errorf("conexão indevida: %s", address)
			}
			return (&net.Dialer{}).DialContext(ctx, network, strings.TrimPrefix(server.URL, "http://"))
		},
	}
	client := newPublicHTTPClient()
	client.Transport.(*http.Transport).DialContext = d.DialContext
	if _, err := fetchPublic(context.Background(), client, "http://public.example"); err == nil {
		t.Fatal("redirecionamento privado aceito")
	}
	if requests != 1 {
		t.Fatalf("requests=%d, want 1", requests)
	}
}

type fakeRoundTripper func(*http.Request) (*http.Response, error)

func (f fakeRoundTripper) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func TestFetchLimitsResponseAndDoesNotSendSecret(t *testing.T) {
	for _, size := range []int{100, maxFetchedBytes + 1} {
		client := &http.Client{Transport: fakeRoundTripper(func(r *http.Request) (*http.Response, error) {
			if r.Header.Get(bridgeTokenHeader) != "" {
				t.Fatal("segredo enviado a página externa")
			}
			return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(strings.Repeat("x", size))), Header: make(http.Header)}, nil
		})}
		body, err := fetchPublic(context.Background(), client, "https://public.example")
		if size <= maxFetchedBytes && (err != nil || len(body) != size) {
			t.Fatalf("página legítima: len=%d err=%v", len(body), err)
		}
		if size > maxFetchedBytes && err == nil {
			t.Fatal("página grande aceita")
		}
	}
}

func TestMediaSpoolRejectsSymlink(t *testing.T) {
	base := t.TempDir()
	target := filepath.Join(base, "target")
	if err := os.Mkdir(target, 0o700); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(base, "link")
	if err := os.Symlink(target, link); err != nil {
		t.Fatal(err)
	}
	t.Setenv("MEDIA_TEMP_DIR", link)
	if _, err := writeMediaTemp("audio", ".ogg", []byte("test")); err == nil {
		t.Fatal("spool com symlink aceito")
	}
	t.Setenv("MEDIA_TEMP_DIR", target)
	path, err := writeMediaTemp("audio", ".ogg", []byte("test"))
	if err != nil || filepath.Dir(path) != target {
		t.Fatalf("path=%s err=%v", path, err)
	}
}
