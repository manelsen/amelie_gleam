package main

import (
	"bytes"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type fakeSizedMedia struct{ size uint64 }

func (f fakeSizedMedia) GetFileLength() uint64 { return f.size }

func TestDeclaredMediaTooLarge(t *testing.T) {
	if declaredMediaTooLarge(fakeSizedMedia{size: maxMediaBytes}) {
		t.Fatal("recusou mídia exatamente no limite")
	}
	if !declaredMediaTooLarge(fakeSizedMedia{size: maxMediaBytes + 1}) {
		t.Fatal("aceitou mídia declarada acima do limite")
	}
	if declaredMediaTooLarge(struct{}{}) {
		t.Fatal("mensagem sem tamanho declarado não deve ser recusada aqui")
	}
}

func newLimitedTempFile(t *testing.T, limit int64) *limitedFile {
	t.Helper()
	f, err := os.CreateTemp(t.TempDir(), "limite_*")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { f.Close() })
	return &limitedFile{file: f, limit: limit}
}

func TestLimitedFileStopsIOCopyAtLimit(t *testing.T) {
	// io.Copy é o caminho que o whatsmeow usa para gravar o download.
	f := newLimitedTempFile(t, 1024)
	_, err := io.Copy(f, bytes.NewReader(make([]byte, 4096)))
	if !errors.Is(err, errMediaTooLarge) {
		t.Fatalf("esperava errMediaTooLarge, veio %v", err)
	}
	info, _ := f.Stat()
	if info.Size() > 1024 {
		t.Fatalf("gravou além do limite: %d bytes", info.Size())
	}
}

func TestLimitedFileAcceptsWithinLimit(t *testing.T) {
	f := newLimitedTempFile(t, 4096)
	if _, err := io.Copy(f, bytes.NewReader(make([]byte, 4096))); err != nil {
		t.Fatalf("recusou escrita dentro do limite: %v", err)
	}
}

func TestLimitedFileWriteAtAndTruncate(t *testing.T) {
	f := newLimitedTempFile(t, 100)
	if _, err := f.WriteAt([]byte("x"), 100); !errors.Is(err, errMediaTooLarge) {
		t.Fatalf("WriteAt além do limite: %v", err)
	}
	if err := f.Truncate(101); !errors.Is(err, errMediaTooLarge) {
		t.Fatalf("Truncate além do limite: %v", err)
	}
	if _, err := f.WriteAt([]byte("x"), 99); err != nil {
		t.Fatalf("WriteAt dentro do limite: %v", err)
	}
}

func TestLimitedFileIsNotOSFile(t *testing.T) {
	// Se fosse *os.File, o whatsmeow pré-alocaria pelo Content-Length.
	var f any = newLimitedTempFile(t, 10)
	if _, ok := f.(*os.File); ok {
		t.Fatal("limitedFile não pode ser *os.File")
	}
	if _, ok := f.(io.ReaderFrom); ok {
		t.Fatal("limitedFile não pode implementar ReaderFrom: io.Copy passaria por cima do limite")
	}
}

func TestDownloadIntoLimitedFileCleansUp(t *testing.T) {
	dir := t.TempDir()
	if err := os.Chmod(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("MEDIA_TEMP_DIR", dir)

	data, err := downloadIntoLimitedFile(func(f *limitedFile) error {
		_, err := f.Write([]byte("conteúdo"))
		return err
	})
	if err != nil || string(data) != "conteúdo" {
		t.Fatalf("esperava o conteúdo gravado, veio %q err=%v", data, err)
	}

	_, err = downloadIntoLimitedFile(func(f *limitedFile) error {
		_, err := io.Copy(f, bytes.NewReader(make([]byte, maxMediaBytes+encryptedMediaOverhead+1)))
		return err
	})
	if !errors.Is(err, errMediaTooLarge) {
		t.Fatalf("esperava errMediaTooLarge, veio %v", err)
	}

	entries, _ := os.ReadDir(dir)
	for _, e := range entries {
		if strings.HasPrefix(e.Name(), mediaTempPrefix) {
			t.Fatalf("arquivo temporário não foi apagado: %s", filepath.Join(dir, e.Name()))
		}
	}
}
