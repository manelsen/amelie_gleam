package main

import (
	"errors"
	"io"
	"os"
)

// maxMediaBytes é o maior arquivo de mídia aceito, igual ao limite que o
// Gleam já aplica no spool (validate_bridge_media).
const maxMediaBytes = 50 * 1024 * 1024

// encryptedMediaOverhead cobre o padding AES-CBC e o MAC de 10 bytes que o
// arquivo cifrado do WhatsApp tem a mais que o conteúdo.
const encryptedMediaOverhead = 64

var errMediaTooLarge = errors.New("mídia excede o limite de 50 MiB")

// sizedMedia é implementado pelas mensagens de mídia do WhatsApp
// (ImageMessage, DocumentMessage, StickerMessage...). O tamanho é declarado
// pelo remetente e pode mentir; serve só para recusar cedo o caso honesto.
type sizedMedia interface {
	GetFileLength() uint64
}

// declaredMediaTooLarge diz se a mensagem declara um arquivo acima do limite.
func declaredMediaTooLarge(msg any) bool {
	sized, ok := msg.(sizedMedia)
	return ok && sized.GetFileLength() > maxMediaBytes
}

// limitedFile recusa qualquer escrita além de limit bytes. É o que de fato
// limita o download, porque o tamanho real pode diferir do declarado.
//
// Não embute *os.File de propósito: o io.Copy usaria o ReadFrom promovido
// e passaria por cima de Write. Também não é um *os.File, então o whatsmeow
// não pré-aloca o arquivo pelo Content-Length informado pelo servidor.
type limitedFile struct {
	file  *os.File
	limit int64
}

func (f *limitedFile) Write(p []byte) (int, error) {
	offset, err := f.file.Seek(0, io.SeekCurrent)
	if err != nil {
		return 0, err
	}
	if offset+int64(len(p)) > f.limit {
		return 0, errMediaTooLarge
	}
	return f.file.Write(p)
}

func (f *limitedFile) WriteAt(p []byte, off int64) (int, error) {
	if off < 0 || off+int64(len(p)) > f.limit {
		return 0, errMediaTooLarge
	}
	return f.file.WriteAt(p, off)
}

func (f *limitedFile) Truncate(size int64) error {
	if size > f.limit {
		return errMediaTooLarge
	}
	return f.file.Truncate(size)
}

func (f *limitedFile) Read(p []byte) (int, error)              { return f.file.Read(p) }
func (f *limitedFile) ReadAt(p []byte, off int64) (int, error) { return f.file.ReadAt(p, off) }
func (f *limitedFile) Seek(off int64, whence int) (int64, error) {
	return f.file.Seek(off, whence)
}
func (f *limitedFile) Stat() (os.FileInfo, error) { return f.file.Stat() }

// downloadIntoLimitedFile cria um arquivo temporário no spool privado, entrega
// ao download um limitedFile sobre ele e devolve o conteúdo. O arquivo é
// sempre apagado ao final.
func downloadIntoLimitedFile(download func(*limitedFile) error) ([]byte, error) {
	dir, err := mediaTempDir()
	if err != nil {
		return nil, err
	}
	tmp, err := os.CreateTemp(dir, mediaTempPrefix+"download_*")
	if err != nil {
		return nil, err
	}
	defer os.Remove(tmp.Name())
	defer tmp.Close()

	if err := download(&limitedFile{file: tmp, limit: maxMediaBytes + encryptedMediaOverhead}); err != nil {
		return nil, err
	}
	if _, err := tmp.Seek(0, io.SeekStart); err != nil {
		return nil, err
	}
	data, err := io.ReadAll(io.LimitReader(tmp, maxMediaBytes+1))
	if err != nil {
		return nil, err
	}
	if len(data) > maxMediaBytes {
		return nil, errMediaTooLarge
	}
	return data, nil
}
