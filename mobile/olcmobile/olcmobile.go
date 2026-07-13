// Package olcmobile exposes a YAML-based gomobile API for the iOS packet tunnel.
package olcmobile

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
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
	errStopTimedOut  = errors.New("olcRTC stop timed out")
)

const defaultStopTimeout = 10 * time.Second

// ai-generated: StartCnc adapts the existing session YAML path to the iOS gomobile API.
func StartCnc(configYAML, dataDir string) error {
	if err := stopCurrent(defaultStopTimeout); err != nil {
		return err
	}

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
	var sawStart bool
	for {
		err, pending := waitReadySnapshot()
		if pending || !errors.Is(err, errNotRunning) {
			sawStart = true
		}
		if !pending {
			if errors.Is(err, errNotRunning) && !sawStart {
				if time.Now().After(deadline) {
					return errStartTimedOut
				}
				time.Sleep(100 * time.Millisecond)
				continue
			}
			return err
		}
		if time.Now().After(deadline) {
			return errStartTimedOut
		}
		time.Sleep(100 * time.Millisecond)
	}
}

// ProbeSocks verifies that the current tunnel can carry an HTTP request through SOCKS.
func ProbeSocks(timeoutMillis int) error {
	mu.Lock()
	addr := socksAddr
	d := done
	mu.Unlock()
	if addr == "" || d == nil {
		return errNotRunning
	}
	timeout := time.Duration(timeoutMillis) * time.Millisecond
	if timeout <= 0 {
		timeout = 10 * time.Second
	}
	return probeSocksAt(addr, timeout)
}

func probeSocksAt(addr string, timeout time.Duration) error {
	conn, err := net.DialTimeout("tcp", addr, timeout)
	if err != nil {
		return fmt.Errorf("dial SOCKS: %w", err)
	}
	defer func() { _ = conn.Close() }()
	if err := conn.SetDeadline(time.Now().Add(timeout)); err != nil {
		return fmt.Errorf("set SOCKS deadline: %w", err)
	}
	if _, err := conn.Write([]byte{0x05, 0x01, 0x00}); err != nil {
		return fmt.Errorf("write SOCKS greeting: %w", err)
	}
	greeting := make([]byte, 2)
	if _, err := io.ReadFull(conn, greeting); err != nil || greeting[0] != 0x05 || greeting[1] != 0x00 {
		return errors.New("SOCKS greeting rejected")
	}
	host := "api.ipify.org"
	request := append([]byte{0x05, 0x01, 0x00, 0x03, byte(len(host))}, []byte(host)...)
	request = append(request, 0x00, 0x50)
	if _, err := conn.Write(request); err != nil {
		return fmt.Errorf("write SOCKS connect: %w", err)
	}
	reply := make([]byte, 4)
	if _, err := io.ReadFull(conn, reply); err != nil {
		return fmt.Errorf("read SOCKS connect: %w", err)
	}
	if reply[0] != 0x05 || reply[1] != 0x00 {
		return fmt.Errorf("SOCKS connect rejected: reply=%d", reply[1])
	}
	var remaining int
	switch reply[3] {
	case 0x01:
		remaining = 4 + 2
	case 0x03:
		length := make([]byte, 1)
		if _, err := io.ReadFull(conn, length); err != nil {
			return fmt.Errorf("read SOCKS address length: %w", err)
		}
		remaining = int(length[0]) + 2
	case 0x04:
		remaining = 16 + 2
	default:
		return fmt.Errorf("SOCKS returned unsupported address type: %d", reply[3])
	}
	if _, err := io.ReadFull(conn, make([]byte, remaining)); err != nil {
		return fmt.Errorf("read SOCKS address: %w", err)
	}
	if _, err := io.WriteString(conn, "GET / HTTP/1.1\r\nHost: api.ipify.org\r\nConnection: close\r\n\r\n"); err != nil {
		return fmt.Errorf("write HTTP probe: %w", err)
	}
	status, err := bufio.NewReader(conn).ReadString('\n')
	if err != nil {
		return fmt.Errorf("read HTTP probe: %w", err)
	}
	if !strings.HasPrefix(status, "HTTP/") {
		return errors.New("invalid HTTP probe response")
	}
	return nil
}

// ai-generated: Stop cancels the active iOS tunnel session.
func Stop() {
	_ = stopCurrent(defaultStopTimeout)
}

func stopCurrent(timeout time.Duration) error {
	mu.Lock()
	cancelFunc := cancel
	d := done
	cancel = nil
	socksAddr = ""
	mu.Unlock()

	if cancelFunc != nil {
		cancelFunc()
	}
	if d == nil {
		return nil
	}
	if timeout <= 0 {
		<-d
		return nil
	}

	timer := time.NewTimer(timeout)
	defer timer.Stop()
	select {
	case <-d:
		return nil
	case <-timer.C:
		return errStopTimedOut
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
