package olcmobile

import (
	"errors"
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
