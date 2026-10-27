package main

import "testing"

func TestSanitizeMime(t *testing.T) {
	cases := map[string]string{
		"":                           "",
		"image/jpeg":                 "image/jpeg",
		"audio/ogg; codecs=opus":     "audio/ogg",
		"Video/MP4":                  "video/mp4",
		"application/vnd.ms-excel":   "application/vnd.ms-excel",
		"video/mp4\r\nX-Injetado: 1": "application/octet-stream",
		`video/mp4"}},"x":{"y":"`:    "application/octet-stream",
		"semtipo":                    "application/octet-stream",
	}
	for in, want := range cases {
		if got := sanitizeMime(in); got != want {
			t.Fatalf("sanitizeMime(%q) = %q, esperava %q", in, got, want)
		}
	}
}
