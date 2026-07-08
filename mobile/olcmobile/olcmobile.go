// Package olcmobile exposes a YAML-based gomobile API for the iOS packet tunnel.
package olcmobile

import (
	"context"
	"errors"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"time"

	"github.com/openlibrecommunity/olcrtc/internal/app/session"
	configpkg "github.com/openlibrecommunity/olcrtc/internal/config"
	_ "golang.org/x/mobile/bind" // ensure gomobile bind sees the mobile tool dependency.
)

var (
	mu        sync.Mutex //nolint:gochecknoglobals // gomobile package owns a single process-wide tunnel.
	cancel    context.CancelFunc
	done      chan struct{}
	errRun    error
	socksAddr string
)

var (
	errNotRunning    = errors.New("olcRTC is not running")
	errStartTimedOut = errors.New("olcRTC start timed out")
)

// ai-generated: StartCnc adapts the existing session YAML path to the iOS gomobile API.
func StartCnc(configYAML, dataDir string) error {
	cfgPath, err := writeConfig(configYAML, dataDir)
	if err != nil {
		return err
	}

	scfg, err := loadSessionConfig(cfgPath)
	if err != nil {
		return err
	}

	ctx, c := context.WithCancel(context.Background())
	localDone := make(chan struct{})
	localSocksAddr := net.JoinHostPort(scfg.SOCKSHost, strconv.Itoa(scfg.SOCKSPort))

	mu.Lock()
	if cancel != nil {
		cancel()
	}
	cancel = c
	done = localDone
	errRun = nil
	socksAddr = localSocksAddr
	mu.Unlock()

	err = session.Run(ctx, scfg)

	mu.Lock()
	if done == localDone {
		cancel = nil
		errRun = err
	}
	mu.Unlock()
	close(localDone)
	return err
}

// ai-generated: WaitReady waits until the local SOCKS listener from StartCnc accepts TCP connections.
func WaitReady(timeoutMillis int) error {
	if timeoutMillis <= 0 {
		return waitReadyOnce()
	}

	deadline := time.Now().Add(time.Duration(timeoutMillis) * time.Millisecond)
	for {
		err, pending := waitReadySnapshot()
		if !pending {
			return err
		}
		if time.Now().After(deadline) {
			return errStartTimedOut
		}
		time.Sleep(100 * time.Millisecond)
	}
}

// ai-generated: Stop cancels the active iOS tunnel session.
func Stop() {
	mu.Lock()
	cancelFunc := cancel
	if cancel != nil {
		cancel = nil
	}
	mu.Unlock()
	if cancelFunc != nil {
		cancelFunc()
	}
}

// ai-generated: writeConfig persists the YAML config so relative config paths stay anchored.
func writeConfig(configYAML, dataDir string) (string, error) {
	if err := os.MkdirAll(dataDir, 0o700); err != nil {
		return "", err
	}
	cfgPath := filepath.Join(dataDir, "cnc.yaml")
	if err := os.WriteFile(cfgPath, []byte(configYAML), 0o600); err != nil {
		return "", err
	}
	return cfgPath, nil
}

// ai-generated: loadSessionConfig follows the CLI config loading/defaulting path.
func loadSessionConfig(cfgPath string) (session.Config, error) {
	session.RegisterDefaults()
	f, err := configpkg.Load(cfgPath)
	if err != nil {
		return session.Config{}, err
	}
	scfg := configpkg.Apply(session.Config{}, f)
	if scfg, err = session.ApplyAuthDefaults(scfg); err != nil {
		return session.Config{}, err
	}
	scfg = session.ApplyTransportDefaults(scfg)
	scfg = session.ApplyLivenessDefaults(scfg)
	if err := session.Validate(scfg); err != nil {
		return session.Config{}, err
	}
	return scfg, nil
}

// ai-generated: waitReadyOnce returns the current readiness state without waiting.
func waitReadyOnce() error {
	err, _ := waitReadySnapshot()
	return err
}

// ai-generated: waitReadySnapshot reports terminal errors or a pending readiness state.
func waitReadySnapshot() (error, bool) {
	mu.Lock()
	addr := socksAddr
	d := done
	runErr := errRun
	running := cancel != nil
	mu.Unlock()

	if addr == "" {
		if runErr != nil {
			return runErr, false
		}
		return errNotRunning, false
	}
	if canConnect(addr) {
		return nil, false
	}
	if !running {
		if runErr != nil {
			return runErr, false
		}
		return errNotRunning, false
	}

	select {
	case <-d:
		mu.Lock()
		runErr = errRun
		mu.Unlock()
		if runErr != nil {
			return runErr, false
		}
		return errNotRunning, false
	default:
		return nil, true
	}
}

// ai-generated: canConnect performs the same readiness probe the Swift extension expects.
func canConnect(addr string) bool {
	conn, err := net.DialTimeout("tcp", addr, 200*time.Millisecond)
	if err != nil {
		return false
	}
	_ = conn.Close()
	return true
}
