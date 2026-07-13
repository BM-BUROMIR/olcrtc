package olcmobile

import (
	"bufio"
	"errors"
	"io"
	"net"
	"testing"
	"time"
)

func resetGlobals(t *testing.T) {
	t.Helper()
	mu.Lock()
	cancel = nil
	done = nil
	errRun = nil
	socksAddr = ""
	mu.Unlock()
}

func TestStopCurrentWaitsForDone(t *testing.T) {
	resetGlobals(t)
	t.Cleanup(func() { resetGlobals(t) })

	doneCh := make(chan struct{})
	cancelCalled := make(chan struct{}, 1)
	mu.Lock()
	cancel = func() { cancelCalled <- struct{}{} }
	done = doneCh
	socksAddr = "127.0.0.1:1"
	mu.Unlock()

	go func() {
		time.Sleep(20 * time.Millisecond)
		close(doneCh)
	}()

	started := time.Now()
	if err := stopCurrent(time.Second); err != nil {
		t.Fatalf("stopCurrent() error = %v", err)
	}
	if elapsed := time.Since(started); elapsed < 20*time.Millisecond {
		t.Fatalf("stopCurrent returned before done closed: %v", elapsed)
	}
	select {
	case <-cancelCalled:
	default:
		t.Fatal("stopCurrent did not call cancel")
	}

	mu.Lock()
	defer mu.Unlock()
	if cancel != nil {
		t.Fatal("cancel was not cleared")
	}
	if socksAddr != "" {
		t.Fatalf("socksAddr = %q, want empty", socksAddr)
	}
}

func TestStopCurrentTimesOut(t *testing.T) {
	resetGlobals(t)
	t.Cleanup(func() { resetGlobals(t) })

	doneCh := make(chan struct{})
	cancelCalled := make(chan struct{}, 1)
	mu.Lock()
	cancel = func() { cancelCalled <- struct{}{} }
	done = doneCh
	socksAddr = "127.0.0.1:1"
	mu.Unlock()

	if err := stopCurrent(10 * time.Millisecond); !errors.Is(err, errStopTimedOut) {
		t.Fatalf("stopCurrent() error = %v, want %v", err, errStopTimedOut)
	}
	select {
	case <-cancelCalled:
	default:
		t.Fatal("stopCurrent did not call cancel")
	}
	close(doneCh)
}

func TestProbeSocksAtChecksEndToEndHTTP(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = listener.Close() })

	go func() {
		conn, acceptErr := listener.Accept()
		if acceptErr != nil {
			return
		}
		defer func() { _ = conn.Close() }()
		greeting := make([]byte, 3)
		_, _ = io.ReadFull(conn, greeting)
		_, _ = conn.Write([]byte{0x05, 0x00})
		head := make([]byte, 5)
		_, _ = io.ReadFull(conn, head)
		hostAndPort := make([]byte, int(head[4])+2)
		_, _ = io.ReadFull(conn, hostAndPort)
		_, _ = conn.Write([]byte{0x05, 0x00, 0x00, 0x01, 127, 0, 0, 1, 0, 80})
		request, _ := bufio.NewReader(conn).ReadString('\n')
		if request != "GET / HTTP/1.1\r\n" {
			return
		}
		_, _ = conn.Write([]byte("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"))
	}()

	if err := probeSocksAt(listener.Addr().String(), 2*time.Second); err != nil {
		t.Fatalf("probeSocksAt() error = %v", err)
	}
}

func TestProbeSocksRequiresRunningTunnel(t *testing.T) {
	resetGlobals(t)
	t.Cleanup(func() { resetGlobals(t) })

	if err := ProbeSocks(100); !errors.Is(err, errNotRunning) {
		t.Fatalf("ProbeSocks() error = %v, want %v", err, errNotRunning)
	}
}
