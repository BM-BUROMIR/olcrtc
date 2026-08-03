// Command gen-configs writes local LiveKit srv/cnc configs for the macOS Docker Desktop stand.
package main

import (
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/livekit/protocol/auth"
)

const (
	apiKey     = "devkey"
	room       = "olcrtc-local-vp8"
	livekitURL = "ws://livekit:7880"
	keyHex     = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"
)

var errUnsafeOutputDir = errors.New("unsafe output dir")

func main() {
	if len(os.Args) > 1 && os.Args[1] == "http-target" {
		runHTTPTarget()
		return
	}

	out := "run"
	if len(os.Args) > 1 {
		out = os.Args[1]
	}
	if err := validateOutputDir(out); err != nil {
		fatal(err)
	}
	// #nosec G703 -- out is validated by validateOutputDir before use.
	if err := os.MkdirAll(out, 0o700); err != nil {
		fatal(err)
	}

	srvToken := token("srv")
	cncToken := token("cnc")
	write(filepath.Join(out, "srv.yaml"), config("srv", srvToken, 0))
	write(filepath.Join(out, "cnc.yaml"), config("cnc", cncToken, 8808))
}

func token(identity string) string {
	grant := &auth.VideoGrant{RoomJoin: true, Room: room}
	grant.SetCanPublish(true)
	grant.SetCanPublishData(true)
	grant.SetCanSubscribe(true)

	apiSecret := os.Getenv("LIVEKIT_API_SECRET")
	if apiSecret == "" {
		apiSecret = strings.Repeat("devsecret", 4) // #nosec G101 -- local throwaway LiveKit dev key.
	}
	jwt, err := auth.NewAccessToken(apiKey, apiSecret).
		SetIdentity(identity).
		SetName(identity).
		SetValidFor(2 * time.Hour).
		SetVideoGrant(grant).
		ToJWT()
	if err != nil {
		fatal(err)
	}
	return jwt
}

func validateOutputDir(out string) error {
	cleaned := filepath.Clean(out)
	if filepath.IsAbs(cleaned) || cleaned == "." || strings.HasPrefix(cleaned, "..") {
		return fmt.Errorf("%w: %s", errUnsafeOutputDir, out)
	}
	return nil
}

func config(mode, token string, socksPort int) string {
	var socks string
	if socksPort > 0 {
		socks = fmt.Sprintf(`socks:
  host: "127.0.0.1"
  port: %d
  max_sessions: 16
`, socksPort)
	}

	return fmt.Sprintf(`mode: %s
auth:
  provider: none
room:
  id: "%s"
  channel: "%s"
crypto:
  key: "%s"
net:
  transport: vp8channel
  dns: "8.8.8.8:53"
engine:
  name: livekit
  url: "%s"
  token: "%s"
  # local LiveKit stand sets rtc.stun_servers: [] and use_external_ip: false.
  stun_servers: []
vp8:
  fps: 30
  batch_size: 8
liveness:
  interval: "2s"
  timeout: "2s"
  failures: 5
%sdata: "/run/olcrtc/%s-data"
debug: true
`, mode, room, room, keyHex, livekitURL, token, socks, mode)
}

func write(path, text string) {
	// #nosec G703 -- path is derived from the validated local output dir.
	if err := os.WriteFile(path, []byte(strings.TrimSpace(text)+"\n"), 0o600); err != nil {
		fatal(err)
	}
}

func runHTTPTarget() {
	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok\n"))
	})
	server := &http.Server{
		Addr:              ":8080",
		Handler:           mux,
		ReadHeaderTimeout: 2 * time.Second,
	}
	if err := server.ListenAndServe(); err != nil {
		fatal(err)
	}
}

func fatal(err error) {
	_, _ = fmt.Fprintln(os.Stderr, err)
	os.Exit(1)
}
