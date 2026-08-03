package e2e

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestLocalLiveKitStandFiles(t *testing.T) {
	root := repoRoot(t)

	compose := readText(t, filepath.Join(root, "deploy/local-livekit/compose.yaml"))
	livekit := readText(t, filepath.Join(root, "deploy/local-livekit/livekit.yaml"))
	generate := readText(t, filepath.Join(root, "deploy/local-livekit/gen-configs.go"))
	smoke := readText(t, filepath.Join(root, "deploy/local-livekit/smoke.sh"))
	dockerignore := readText(t, filepath.Join(root, ".dockerignore"))
	readme := readText(t, filepath.Join(root, "docs/local-livekit.ru.md"))

	assertContains(t, compose, "${LIVEKIT_TCP_PORT:-7881}:${LIVEKIT_TCP_PORT:-7881}/tcp")
	assertContains(t, compose, "LIVEKIT_KEYS")
	assertContains(t, compose, "${LIVEKIT_API_KEY:-devkey}")
	assertContains(t, compose, "${LIVEKIT_API_SECRET:-devsecretdevsecretdevsecretdevsecret}")
	assertContains(t, livekit, "tcp_port: 7881")
	assertContains(t, livekit, "use_external_ip: false")
	assertContains(t, livekit, "port_range_start: 50000")
	assertContains(t, livekit, "port_range_end: 50020")

	assertContains(t, generate, "transport: vp8channel")
	assertContains(t, generate, "auth:\n  provider: none")
	assertContains(t, generate, "stun_servers: []")
	assertContains(t, generate, "SetCanPublish(true)")
	assertContains(t, generate, "SetCanSubscribe(true)")
	assertContains(t, generate, "http-target")

	assertContains(t, smoke, "peer latched")
	assertContains(t, smoke, "SOCKS5 server listening")
	assertContains(t, smoke, "--socks5-hostname")
	assertContains(t, smoke, "GOOS=linux")
	assertContains(t, smoke, "HTTP_STATUS")
	assertContains(t, smoke, "200")
	assertContains(t, smoke, "vp8channel")
	assertContains(t, dockerignore, "!deploy/local-livekit/run/olcrtc-linux")

	assertContains(t, readme, "peer latched")
	assertContains(t, readme, "SOCKS5 server listening")
	assertContains(t, readme, "HTTP 200")
	assertContains(t, readme, "vp8channel")
}

func repoRoot(t *testing.T) string {
	t.Helper()

	dir, err := os.Getwd()
	if err != nil {
		t.Fatalf("get cwd: %v", err)
	}
	for {
		if _, err := os.Stat(filepath.Join(dir, "go.mod")); err == nil {
			return dir
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			t.Fatal("go.mod not found")
		}
		dir = parent
	}
}

func readText(t *testing.T, path string) string {
	t.Helper()

	// #nosec G304 -- test reads fixed repository paths assembled by the caller.
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	return string(data)
}

func assertContains(t *testing.T, text, needle string) {
	t.Helper()

	if !strings.Contains(text, needle) {
		t.Fatalf("missing %q", needle)
	}
}
