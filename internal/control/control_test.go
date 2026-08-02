package control

import (
	"context"
	"encoding/binary"
	"errors"
	"io"
	"net"
	"testing"
	"time"
)

func controlPair(t *testing.T) (net.Conn, net.Conn) {
	t.Helper()
	a, b := net.Pipe()
	t.Cleanup(func() {
		_ = a.Close()
		_ = b.Close()
	})
	return a, b
}

func TestRunPingPongReportsRTT(t *testing.T) {
	a, b := controlPair(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	got := make(chan Health, 1)
	cfg := Config{
		Interval: 10 * time.Millisecond,
		Timeout:  100 * time.Millisecond,
		Failures: 2,
		OnPong: func(h Health) {
			select {
			case got <- h:
			default:
			}
		},
	}
	errCh := make(chan error, 2)
	go func() { errCh <- Run(ctx, a, cfg) }()
	go func() { errCh <- Run(ctx, b, cfg) }()

	select {
	case h := <-got:
		if h.Seq == 0 {
			t.Fatal("Health.Seq = 0")
		}
		if h.RTT < 0 {
			t.Fatalf("Health.RTT = %v", h.RTT)
		}
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for pong health")
	}

	cancel()
	for range 2 {
		if err := <-errCh; err != nil {
			t.Fatalf("Run() after cancel = %v", err)
		}
	}
}

func TestRunMarksUnhealthyAfterMissedPongs(t *testing.T) {
	a, b := controlPair(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	go func() {
		_, _ = io.Copy(io.Discard, b)
	}()

	missedCh := make(chan int, 1)
	missedCallbackCh := make(chan int, 1)
	errCh := make(chan error, 1)
	go func() {
		errCh <- Run(ctx, a, Config{
			Interval: 10 * time.Millisecond,
			Timeout:  5 * time.Millisecond,
			Failures: 2,
			OnMissedPong: func(missed int) {
				select {
				case missedCallbackCh <- missed:
				default:
				}
			},
			OnUnhealthy: func(missed int) { missedCh <- missed },
		})
	}()

	select {
	case err := <-errCh:
		if !errors.Is(err, ErrUnhealthy) {
			t.Fatalf("Run() error = %v, want ErrUnhealthy", err)
		}
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for unhealthy result")
	}
	if missed := <-missedCh; missed < 2 {
		t.Fatalf("missed = %d, want >= 2", missed)
	}
	if missed := <-missedCallbackCh; missed < 1 {
		t.Fatalf("missed callback = %d, want >= 1", missed)
	}
}

func TestLatePongResetsFailuresAndReportsPong(t *testing.T) {
	base := time.Unix(10, 0)
	now := base
	got := make(chan Health, 1)
	s := &state{
		cfg: Config{
			Timeout:  10 * time.Millisecond,
			Failures: 4,
			OnPong: func(h Health) {
				got <- h
			},
		},
		pending: make(map[uint64]time.Time),
		now:     func() time.Time { return now },
		out:     make(chan Message, 4),
	}

	if err := s.sendProbe(context.Background()); err != nil {
		t.Fatalf("sendProbe() error = %v", err)
	}
	now = base.Add(11 * time.Millisecond)
	if err := s.sendProbe(context.Background()); err != nil {
		t.Fatalf("sendProbe(timeout) error = %v", err)
	}
	if s.failures != 1 {
		t.Fatalf("failures after timeout = %d, want 1", s.failures)
	}

	s.handlePong(Message{Version: ProtoVersion, Type: TypePong, Seq: 1})

	if s.failures != 0 {
		t.Fatalf("failures after late pong = %d, want 0", s.failures)
	}
	select {
	case h := <-got:
		if h.Seq != 1 {
			t.Fatalf("Health.Seq = %d, want 1", h.Seq)
		}
		if h.RTT != 11*time.Millisecond {
			t.Fatalf("Health.RTT = %v, want 11ms", h.RTT)
		}
	case <-time.After(time.Second):
		t.Fatal("OnPong was not called for late pong")
	}
}

func TestUnknownPongDoesNotResetFailures(t *testing.T) {
	called := false
	s := &state{
		cfg: Config{
			OnPong: func(Health) {
				called = true
			},
		},
		pending:  make(map[uint64]time.Time),
		now:      time.Now,
		failures: 2,
	}

	s.handlePong(Message{Version: ProtoVersion, Type: TypePong, Seq: 99})

	if s.failures != 2 {
		t.Fatalf("failures = %d, want 2", s.failures)
	}
	if called {
		t.Fatal("OnPong called for unknown seq")
	}
}

func TestLatePongIsConsumedOnce(t *testing.T) {
	base := time.Unix(20, 0)
	now := base
	calls := 0
	s := &state{
		cfg: Config{
			Timeout:  10 * time.Millisecond,
			Failures: 4,
			OnPong: func(Health) {
				calls++
			},
		},
		pending: make(map[uint64]time.Time),
		now:     func() time.Time { return now },
		out:     make(chan Message, 4),
	}

	if err := s.sendProbe(context.Background()); err != nil {
		t.Fatalf("sendProbe() error = %v", err)
	}
	now = base.Add(11 * time.Millisecond)
	if err := s.sendProbe(context.Background()); err != nil {
		t.Fatalf("sendProbe(timeout) error = %v", err)
	}
	s.handlePong(Message{Version: ProtoVersion, Type: TypePong, Seq: 1})
	s.failures = 2
	s.handlePong(Message{Version: ProtoVersion, Type: TypePong, Seq: 1})

	if calls != 1 {
		t.Fatalf("OnPong calls = %d, want 1", calls)
	}
	if s.failures != 2 {
		t.Fatalf("failures after duplicate late pong = %d, want 2", s.failures)
	}
}

func TestExpiredPongWindowIsBounded(t *testing.T) {
	base := time.Unix(30, 0)
	now := base
	calls := 0
	s := &state{
		cfg: Config{
			Timeout:  time.Millisecond,
			Interval: time.Millisecond,
			Failures: expiredPongSeqLimit + 10,
			OnPong: func(Health) {
				calls++
			},
		},
		pending: make(map[uint64]time.Time),
		now:     func() time.Time { return now },
		out:     make(chan Message, expiredPongSeqLimit+4),
	}

	for range expiredPongSeqLimit + 2 {
		if err := s.sendProbe(context.Background()); err != nil {
			t.Fatalf("sendProbe() error = %v", err)
		}
		now = now.Add(2 * time.Millisecond)
	}
	s.failures = 3
	s.handlePong(Message{Version: ProtoVersion, Type: TypePong, Seq: 1})

	if calls != 0 {
		t.Fatalf("OnPong calls = %d, want 0 for pruned expired seq", calls)
	}
	if s.failures != 3 {
		t.Fatalf("failures = %d, want 3 for pruned expired seq", s.failures)
	}
	if len(s.expiredPongs) > expiredPongSeqLimit {
		t.Fatalf("expired pong window size = %d, want <= %d", len(s.expiredPongs), expiredPongSeqLimit)
	}
}

func TestRunRejectsBadProtocolVersion(t *testing.T) {
	a, b := controlPair(t)
	errCh := make(chan error, 1)
	go func() {
		errCh <- Run(context.Background(), a, Config{Interval: time.Hour})
	}()
	if err := writeFrame(b, Message{Version: 999, Type: TypePing, Seq: 1}); err != nil {
		t.Fatalf("writeFrame() error = %v", err)
	}

	select {
	case err := <-errCh:
		if !errors.Is(err, ErrProtocolVersion) {
			t.Fatalf("Run() error = %v, want ErrProtocolVersion", err)
		}
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for protocol error")
	}
}

func TestRunStopsOnPeerClose(t *testing.T) {
	a, b := controlPair(t)
	errCh := make(chan error, 1)
	go func() {
		errCh <- Run(context.Background(), a, Config{Interval: time.Hour})
	}()
	if err := SendClose(b); err != nil {
		t.Fatalf("SendClose() error = %v", err)
	}

	select {
	case err := <-errCh:
		if !errors.Is(err, ErrClosedByPeer) {
			t.Fatalf("Run() error = %v, want ErrClosedByPeer", err)
		}
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for peer close")
	}
}

func TestReadFrameRejectsTooLarge(t *testing.T) {
	a, b := controlPair(t)
	go func() {
		var hdr [4]byte
		binary.BigEndian.PutUint32(hdr[:], MaxMessageSize+1)
		_, _ = b.Write(hdr[:])
	}()
	_, err := readFrame(a)
	if !errors.Is(err, ErrFrameTooLarge) {
		t.Fatalf("readFrame() error = %v, want ErrFrameTooLarge", err)
	}
}
