// The launcher keeps the game up to date: it compares the installed version
// with the latest GitHub release, downloads the new build when they differ,
// and starts the game.
package main

import (
	"archive/zip"
	"bufio"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

const releases = "https://github.com/danielszaltans/theGame/releases"

func main() {
	if err := run(); err != nil {
		fmt.Println("\nError:", err)
		fmt.Println("Press Enter to close.")
		bufio.NewReader(os.Stdin).ReadString('\n')
		os.Exit(1)
	}
}

func run() error {
	dir, err := installDir()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	versionFile := filepath.Join(dir, "version.txt")
	gameDir := filepath.Join(dir, "game")

	installedBytes, _ := os.ReadFile(versionFile)
	installed := strings.TrimSpace(string(installedBytes))

	fmt.Println("Checking for updates...")
	latest, err := latestVersion()
	switch {
	case err != nil && installed == "":
		return fmt.Errorf("the game is not installed yet and the download failed: %w", err)
	case err != nil:
		fmt.Printf("Could not check for updates (%v). Starting %s.\n", err, installed)
	case latest != installed:
		fmt.Printf("Updating %s -> %s\n", orNone(installed), latest)
		if err := install(latest, dir, gameDir); err != nil {
			if installed == "" {
				return fmt.Errorf("install failed: %w", err)
			}
			fmt.Printf("Update failed (%v). Starting %s.\n", err, installed)
			break
		}
		if err := os.WriteFile(versionFile, []byte(latest+"\n"), 0o644); err != nil {
			return err
		}
	default:
		fmt.Println("Up to date:", installed)
	}

	game := exec.Command(filepath.Join(gameDir, gameBinary()))
	game.Dir = gameDir
	return game.Start()
}

func installDir() (string, error) {
	if runtime.GOOS == "windows" {
		if base := os.Getenv("LOCALAPPDATA"); base != "" {
			return filepath.Join(base, "theGame"), nil
		}
	}
	if base := os.Getenv("XDG_DATA_HOME"); base != "" {
		return filepath.Join(base, "theGame"), nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, ".local", "share", "theGame"), nil
}

func gameBinary() string {
	if runtime.GOOS == "windows" {
		return "game.exe"
	}
	return "game.x86_64"
}

func orNone(version string) string {
	if version == "" {
		return "(not installed)"
	}
	return version
}

func latestVersion() (string, error) {
	client := http.Client{Timeout: 10 * time.Second}
	response, err := client.Get(releases + "/latest/download/version.txt")
	if err != nil {
		return "", err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return "", fmt.Errorf("GitHub answered %s", response.Status)
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, 64))
	if err != nil {
		return "", err
	}
	version := strings.TrimSpace(string(body))
	if !strings.HasPrefix(version, "v") {
		return "", fmt.Errorf("unexpected version %q", version)
	}
	return version, nil
}

// install replaces gameDir only after the new build is fully downloaded and
// unpacked, so a failed update leaves the old build playable.
func install(version, dir, gameDir string) error {
	archive := filepath.Join(dir, "download.zip")
	defer os.Remove(archive)
	url := fmt.Sprintf("%s/download/%s/game-%s.zip", releases, version, runtime.GOOS)
	if err := download(url, archive); err != nil {
		return err
	}

	staging := filepath.Join(dir, "game.new")
	if err := os.RemoveAll(staging); err != nil {
		return err
	}
	if err := unzip(archive, staging); err != nil {
		return err
	}
	if err := os.RemoveAll(gameDir); err != nil {
		return fmt.Errorf("could not replace the old version (is the game still running?): %w", err)
	}
	return os.Rename(staging, gameDir)
}

func download(url, target string) error {
	response, err := http.Get(url)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return fmt.Errorf("GitHub answered %s for %s", response.Status, url)
	}
	file, err := os.Create(target)
	if err != nil {
		return err
	}
	defer file.Close()
	_, err = io.Copy(file, &progress{reader: response.Body, total: response.ContentLength})
	fmt.Println()
	return err
}

type progress struct {
	reader  io.Reader
	total   int64
	done    int64
	printed time.Time
}

func (p *progress) Read(buffer []byte) (int, error) {
	n, err := p.reader.Read(buffer)
	p.done += int64(n)
	if time.Since(p.printed) > 100*time.Millisecond || err == io.EOF {
		p.printed = time.Now()
		const mb = 1 << 20
		if p.total > 0 {
			fmt.Printf("\rDownloading %d%% (%d / %d MB)", p.done*100/p.total, p.done/mb, p.total/mb)
		} else {
			fmt.Printf("\rDownloading %d MB", p.done/mb)
		}
	}
	return n, err
}

func unzip(archive, target string) error {
	reader, err := zip.OpenReader(archive)
	if err != nil {
		return err
	}
	defer reader.Close()
	for _, entry := range reader.File {
		if !filepath.IsLocal(entry.Name) {
			return errors.New("the download contains an unsafe path: " + entry.Name)
		}
		path := filepath.Join(target, entry.Name)
		if entry.FileInfo().IsDir() {
			if err := os.MkdirAll(path, 0o755); err != nil {
				return err
			}
			continue
		}
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			return err
		}
		if err := extract(entry, path); err != nil {
			return err
		}
	}
	return nil
}

func extract(entry *zip.File, path string) error {
	source, err := entry.Open()
	if err != nil {
		return err
	}
	defer source.Close()
	file, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, entry.Mode().Perm()|0o600)
	if err != nil {
		return err
	}
	defer file.Close()
	_, err = io.Copy(file, source)
	return err
}
