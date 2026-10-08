// This file tests the desktop command's paths that do not open a native window.

//go:build desktop

package main

import (
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/aarora79/meru/internal/about"
)

// TestVersionStopsBeforeWails checks that package inspection can read the stamped
// version without starting GTK or connecting to merud.
func TestVersionStopsBeforeWails(t *testing.T) {
	old := os.Stdout
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	os.Stdout = writer
	t.Cleanup(func() { os.Stdout = old })

	err = run([]string{"--version"})
	if closeErr := writer.Close(); err == nil && closeErr != nil {
		err = closeErr
	}
	output, readErr := io.ReadAll(reader)
	if readErr != nil {
		t.Fatal(readErr)
	}
	if err != nil {
		t.Fatalf("run --version: %v", err)
	}
	if got, want := strings.TrimSpace(string(output)), about.Version(); got != want {
		t.Errorf("version = %q, want %q", got, want)
	}
}

// TestLinuxApplicationIDMatchesDesktopFile keeps GNOME's menu entry, window and
// icon grouped under one reverse-domain name.
func TestLinuxApplicationIDMatchesDesktopFile(t *testing.T) {
	path := filepath.Join("..", "..", "deploy", "linux", linuxApplicationID+".desktop")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	text := string(data)
	for _, want := range []string{
		"Icon=" + linuxApplicationID,
		"StartupWMClass=" + linuxApplicationID,
	} {
		if !strings.Contains(text, want+"\n") {
			t.Errorf("%s lacks %q", path, want)
		}
	}
}
