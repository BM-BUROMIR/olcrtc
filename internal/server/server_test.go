package server

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"strings"
	"testing"
	"time"

	"github.com/openlibrecommunity/olcrtc/internal/control"
	cryptopkg "github.com/openlibrecommunity/olcrtc/internal/crypto"
	"github.com/openlibrecommunity/olcrtc/internal/handshake"
	"github.com/openlibrecommunity/olcrtc/internal/muxconn"
	"github.com/openlibrecommunity/olcrtc/internal/runtime"
	"github.com/openlibrecommunity/olcrtc/internal/transport"
	"github.com/xtaci/smux"
)

const (
	testConnectAddr = "127.0.0.1"
	testConnectCmd  = connectCommand
)

func TestSetupCipher(t *testing.T) {
	keyHex := "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"
	cipher, err := setupCipher(keyHex)
	if err != nil {
		t.Fatalf("setupCipher() error = %v", err)
	}
	if cipher == nil {
		t.Fatal("setupCipher() returned nil cipher")
	}
}

func TestSetupCipherRejectsBadInput(t *testing.T) {
	if _, err := setupCipher(""); !errors.Is(err, ErrKeyRequired) {
		t.Fatalf("setupCipher() error = %v, want %v", err, ErrKeyRequired)
	}
	if _, err := setupCipher("zz"); err == nil {
		t.Fatal("setupCipher() unexpectedly succeeded for bad hex")
	}
	if _, err := setupCipher("00"); !errors.Is(err, ErrKeySize) {
		t.Fatalf("setupCipher() error = %v, want ErrKeySize", err)
	}
}

func TestSmuxConfig(t *testing.T) {
	cfg := smuxConfig(0)
	if cfg.Version != 2 || cfg.KeepAliveDisabled || cfg.MaxFrameSize != 32768 ||
		cfg.MaxReceiveBuffer != 32*1024*1024 || cfg.MaxStreamBuffer != 4*1024*1024 {
		t.Fatalf("smuxConfig(0) = %+v", cfg)
	}
	capped := smuxConfig(4096)
	want := 4096 - runtime.SmuxWireOverhead
	if capped.MaxFrameSize != want {
		t.Fatalf("smuxConfig(4096).MaxFrameSize = %d, want %d",
			capped.MaxFrameSize, want)
	}
}

func TestParseConnectRequest(t *testing.T) {
	buf, err := json.Marshal(ConnectRequest{
		Cmd:  testConnectCmd,
		Addr: "example.com", //nolint:goconst // test literal, repetition is intentional
		Port: 443,
	})
	if err != nil {
		t.Fatalf("Marshal() error = %v", err)
	}

	req, ok := parseConnectRequest(buf)
	if !ok {
		t.Fatal("parseConnectRequest() returned ok=false")
	}
	if req.Addr != "example.com" || req.Port != 443 {
		t.Fatalf("parseConnectRequest() = %+v", req)
	}

	if _, ok := parseConnectRequest([]byte("not-json")); ok {
		t.Fatal("parseConnectRequest() unexpectedly accepted invalid json")
	}
	if _, ok := parseConnectRequest([]byte(`{"cmd":"other"}`)); ok {
		t.Fatal("parseConnectRequest() unexpectedly accepted wrong command")
	}
}

func TestDefaultAuthHook(t *testing.T) {
	sid, err := defaultAuthHook("dev", map[string]any{"x": 1})
	if err != nil {
		t.Fatalf("defaultAuthHook() err = %v", err)
	}
	if sid == "" {
		t.Fatal("defaultAuthHook() returned empty session id")
	}
}

//nolint:cyclop // table-driven test naturally has many branches
func TestSocks5ConnectSuccess(t *testing.T) {
	s := &Server{}
	server, client := net.Pipe()
	defer func() {
		_ = server.Close()
		_ = client.Close()
	}()

	done := make(chan error, 1)
	go func() {
		done <- s.socks5Connect(server, "example.com", 443)
	}()

	auth := make([]byte, 3)
	if _, err := io.ReadFull(client, auth); err != nil {
		t.Fatalf("ReadFull(auth) error = %v", err)
	}
	if !bytes.Equal(auth, []byte{5, 1, 0}) {
		t.Fatalf("auth request = %v", auth)
	}
	if _, err := client.Write([]byte{5, 0}); err != nil {
		t.Fatalf("Write(auth resp) error = %v", err)
	}

	req := make([]byte, 18)
	if _, err := io.ReadFull(client, req); err != nil {
		t.Fatalf("ReadFull(connect req) error = %v", err)
	}
	if req[0] != 5 || req[1] != 1 || req[3] != 3 || req[4] != byte(len("example.com")) {
		t.Fatalf("connect request header = %v", req[:5])
	}
	if string(req[5:16]) != "example.com" {
		t.Fatalf("connect request addr = %q", req[5:16])
	}
	if req[16] != 0x01 || req[17] != 0xbb {
		t.Fatalf("connect request port bytes = %v", req[16:18])
	}
	if _, err := client.Write([]byte{5, 0, 0, 1, 0, 0, 0, 0, 0, 0}); err != nil {
		t.Fatalf("Write(connect resp) error = %v", err)
	}

	if err := <-done; err != nil {
		t.Fatalf("socks5Connect() error = %v", err)
	}
}

func TestSocks5ConnectErrors(t *testing.T) {
	s := &Server{}

	server, client := net.Pipe()
	defer func() {
		_ = server.Close()
		_ = client.Close()
	}()

	done := make(chan error, 1)
	go func() {
		done <- s.socks5Connect(server, "example.com", 443)
	}()

	auth := make([]byte, 3)
	if _, err := io.ReadFull(client, auth); err != nil {
		t.Fatalf("ReadFull(auth) error = %v", err)
	}
	if _, err := client.Write([]byte{5, 1}); err != nil {
		t.Fatalf("Write(auth resp) error = %v", err)
	}
	if err := <-done; !errors.Is(err, ErrSocks5AuthFailed) {
		t.Fatalf("socks5Connect() error = %v, want %v", err, ErrSocks5AuthFailed)
	}

	server2, client2 := net.Pipe()
	defer func() {
		_ = server2.Close()
		_ = client2.Close()
	}()

	done = make(chan error, 1)
	go func() {
		done <- s.socks5Connect(server2, "example.com", 443)
	}()

	if _, err := io.ReadFull(client2, auth); err != nil {
		t.Fatalf("ReadFull(auth2) error = %v", err)
	}
	if _, err := client2.Write([]byte{5, 0}); err != nil {
		t.Fatalf("Write(auth2 resp) error = %v", err)
	}

	req := make([]byte, 18)
	if _, err := io.ReadFull(client2, req); err != nil {
		t.Fatalf("ReadFull(req2) error = %v", err)
	}
	if _, err := client2.Write([]byte{5, 4, 0, 1, 0, 0, 0, 0, 0, 0}); err != nil {
		t.Fatalf("Write(connect2 resp) error = %v", err)
	}
	if err := <-done; !errors.Is(err, ErrSocks5ConnectFailed) {
		t.Fatalf("socks5Connect() error = %v, want %v", err, ErrSocks5ConnectFailed)
	}
}

func TestSetupResolver(t *testing.T) {
	s := &Server{dnsServer: "127.0.0.1:53"}
	s.setupResolver()
	if s.resolver == nil || !s.resolver.PreferGo || s.resolver.Dial == nil {
		t.Fatalf("setupResolver() = %+v", s.resolver)
	}
}

func TestOnDataWithNilConn(_ *testing.T) {
	s := &Server{}
	s.onData([]byte("ignored"))
}

type serverLinkStub struct {
	closed      bool
	resetCount  int
	resetCh     chan struct{}
	reconnectCh chan string
}

func (s *serverLinkStub) Connect(context.Context) error   { return nil }
func (s *serverLinkStub) Send([]byte) error               { return nil }
func (s *serverLinkStub) Close() error                    { s.closed = true; return nil }
func (s *serverLinkStub) SetReconnectCallback(func())     {}
func (s *serverLinkStub) SetShouldReconnect(func() bool)  {}
func (s *serverLinkStub) SetEndedCallback(func(string))   {}
func (s *serverLinkStub) WatchConnection(context.Context) {}
func (s *serverLinkStub) CanSend() bool                   { return true }
func (s *serverLinkStub) Features() transport.Features    { return transport.Features{} }
func (s *serverLinkStub) Reconnect(reason string) {
	if s.reconnectCh != nil {
		select {
		case s.reconnectCh <- reason:
		default:
		}
	}
}
func (s *serverLinkStub) ResetPeer() {
	s.resetCount++
	if s.resetCh != nil {
		select {
		case s.resetCh <- struct{}{}:
		default:
		}
	}
}

func TestShutdownClosesLinkAndConn(t *testing.T) {
	cipher, err := cryptopkg.NewCipher("01234567890123456789012345678901")
	if err != nil {
		t.Fatalf("NewCipher() error = %v", err)
	}
	ln := &serverLinkStub{}
	s := &Server{
		ln:     ln,
		cipher: cipher,
		conn:   muxconn.New(ln, cipher),
	}
	s.shutdown()
	if !ln.closed {
		t.Fatal("shutdown() did not close link")
	}
}

func TestDialWithoutProxy(t *testing.T) {
	var lc net.ListenConfig
	ln, err := lc.Listen(context.Background(), "tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("Listen() error = %v", err)
	}
	defer func() { _ = ln.Close() }()

	done := make(chan struct{})
	go func() {
		conn, err := ln.Accept()
		if err == nil {
			_ = conn.Close()
			close(done)
		}
	}()

	tcpAddr, ok := ln.Addr().(*net.TCPAddr)
	if !ok {
		t.Fatalf("listener addr type = %T, want *net.TCPAddr", ln.Addr())
	}
	s := &Server{resolver: net.DefaultResolver}
	conn, err := s.dial(ConnectRequest{Addr: testConnectAddr, Port: tcpAddr.Port})
	if err != nil {
		t.Fatalf("dial() error = %v", err)
	}
	_ = conn.Close()
	<-done
}

func TestDialProxyError(t *testing.T) {
	s := &Server{socksProxyAddr: testConnectAddr, socksProxyPort: 1}
	if _, err := s.dial(ConnectRequest{Addr: "example.com", Port: 443}); err == nil || !strings.Contains(err.Error(), "failed to dial proxy") { //nolint:lll // long test description
		t.Fatalf("dial() error = %v", err)
	}
}

func TestSocks5ConnectTruncatesLongDomain(t *testing.T) {
	s := &Server{}
	server, client := net.Pipe()
	defer func() {
		_ = server.Close()
		_ = client.Close()
	}()

	longHost := strings.Repeat("a", 300)
	done := make(chan error, 1)
	go func() {
		done <- s.socks5Connect(server, longHost, 443)
	}()

	auth := make([]byte, 3)
	if _, err := io.ReadFull(client, auth); err != nil {
		t.Fatalf("ReadFull(auth) error = %v", err)
	}
	if _, err := client.Write([]byte{5, 0}); err != nil {
		t.Fatalf("Write(auth resp) error = %v", err)
	}

	req := make([]byte, 262)
	if _, err := io.ReadFull(client, req); err != nil {
		t.Fatalf("ReadFull(connect req) error = %v", err)
	}
	if req[4] != 255 {
		t.Fatalf("domain len byte = %d, want 255", req[4])
	}
	if _, err := client.Write([]byte{5, 0, 0, 1, 0, 0, 0, 0, 0, 0}); err != nil {
		t.Fatalf("Write(connect resp) error = %v", err)
	}
	if err := <-done; err != nil {
		t.Fatalf("socks5Connect() error = %v", err)
	}
}

func TestHandleStreamDispatchAfterConnect(t *testing.T) {
	a, b := net.Pipe()
	defer func() {
		_ = a.Close()
		_ = b.Close()
	}()

	serverSess, err := smux.Server(a, smuxConfig(0))
	if err != nil {
		t.Fatalf("smux.Server() error = %v", err)
	}
	defer func() { _ = serverSess.Close() }()
	clientSess, err := smux.Client(b, smuxConfig(0))
	if err != nil {
		t.Fatalf("smux.Client() error = %v", err)
	}
	defer func() { _ = clientSess.Close() }()

	done := make(chan struct{})
	go func() {
		stream, err := serverSess.AcceptStream()
		if err == nil {
			(&Server{}).handleStream(context.Background(), stream, "")
		}
		close(done)
	}()

	stream, err := clientSess.OpenStream()
	if err != nil {
		t.Fatalf("OpenStream() error = %v", err)
	}
	req, err := json.Marshal(ConnectRequest{
		Cmd:  testConnectCmd,
		Addr: testConnectAddr,
		Port: 1, // unreachable port - dispatch will fail dial and exit
	})
	if err != nil {
		t.Fatalf("Marshal() error = %v", err)
	}
	if _, err := stream.Write(req); err != nil {
		t.Fatalf("Write() error = %v", err)
	}
	<-done
}

func TestReinstallSessionFiresOnClose(t *testing.T) {
	cipher, err := cryptopkg.NewCipher("01234567890123456789012345678901")
	if err != nil {
		t.Fatalf("NewCipher() error = %v", err)
	}
	var got struct {
		sid    string
		reason string
	}
	s := &Server{
		ln:        &serverLinkStub{},
		cipher:    cipher,
		sessionID: "sid-123",
		deviceID:  "dev-123",
		onClose:   func(sid, reason string) { got.sid = sid; got.reason = reason },
	}
	s.closeSession()
	if got.sid != "sid-123" || got.reason != "closed" {
		t.Fatalf("onClose = %+v, want {sid-123 closed}", got)
	}
}

func TestAcceptHandshakeIgnoresStaleControlSessionWithoutReset(t *testing.T) {
	liveA, liveB := net.Pipe()
	defer func() {
		_ = liveA.Close()
		_ = liveB.Close()
	}()
	liveSess, err := smux.Server(liveA, smuxConfig(0))
	if err != nil {
		t.Fatalf("smux.Server(live) error = %v", err)
	}
	defer func() { _ = liveSess.Close() }()

	staleA, staleB := net.Pipe()
	defer func() {
		_ = staleA.Close()
		_ = staleB.Close()
	}()
	staleControlSess, err := smux.Server(staleA, controlSmuxConfig(0))
	if err != nil {
		t.Fatalf("smux.Server(stale control) error = %v", err)
	}
	defer func() { _ = staleControlSess.Close() }()
	staleClientSess, err := smux.Client(staleB, controlSmuxConfig(0))
	if err != nil {
		t.Fatalf("smux.Client(stale control) error = %v", err)
	}

	ln := &serverLinkStub{}
	s := &Server{
		ln:          ln,
		session:     liveSess,
		controlSess: liveSess,
	}
	_ = staleClientSess.Close()

	done := make(chan bool, 1)
	go func() {
		done <- s.acceptHandshake(context.Background(), staleControlSess)
	}()

	select {
	case ok := <-done:
		if ok {
			t.Fatal("acceptHandshake() unexpectedly succeeded")
		}
	case <-time.After(time.Second):
		t.Fatal("acceptHandshake() did not return after stale control session closed")
	}
	if ln.resetCount != 0 {
		t.Fatalf("ResetPeer calls = %d, want 0 for stale control session", ln.resetCount)
	}
}

func TestStaleControlLoopDoesNotReconnectCarrier(t *testing.T) {
	liveA, liveB := net.Pipe()
	defer func() {
		_ = liveA.Close()
		_ = liveB.Close()
	}()
	liveSess, err := smux.Server(liveA, smuxConfig(0))
	if err != nil {
		t.Fatalf("smux.Server(live) error = %v", err)
	}
	defer func() { _ = liveSess.Close() }()

	staleA, staleB := net.Pipe()
	defer func() {
		_ = staleA.Close()
		_ = staleB.Close()
	}()
	staleServerSess, err := smux.Server(staleA, controlSmuxConfig(0))
	if err != nil {
		t.Fatalf("smux.Server(stale) error = %v", err)
	}
	defer func() { _ = staleServerSess.Close() }()
	staleClientSess, err := smux.Client(staleB, controlSmuxConfig(0))
	if err != nil {
		t.Fatalf("smux.Client(stale) error = %v", err)
	}
	defer func() { _ = staleClientSess.Close() }()

	serverStreamCh := make(chan *smux.Stream, 1)
	go func() {
		stream, acceptErr := staleServerSess.AcceptStream()
		if acceptErr == nil {
			serverStreamCh <- stream
		}
	}()
	clientStream, err := staleClientSess.OpenStream()
	if err != nil {
		t.Fatalf("OpenStream() error = %v", err)
	}
	serverStream := <-serverStreamCh

	ln := &serverLinkStub{reconnectCh: make(chan string, 1)}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	s := &Server{
		ln:          ln,
		session:     liveSess,
		controlSess: liveSess,
		health:      runtime.NewHealthTracker(nil),
		done:        make(chan struct{}),
	}
	s.startControlLoop(ctx, staleServerSess, serverStream)
	_ = clientStream.Close()
	_ = staleClientSess.Close()

	select {
	case reason := <-ln.reconnectCh:
		t.Fatalf("stale control loop triggered carrier reconnect: %s", reason)
	case <-time.After(200 * time.Millisecond):
	}
}

//nolint:cyclop // integration-style control loop test needs setup and async assertions together
func TestStartControlLoopReportsPong(t *testing.T) {
	a, b := net.Pipe()
	defer func() {
		_ = a.Close()
		_ = b.Close()
	}()

	serverSess, err := smux.Server(a, smuxConfig(0))
	if err != nil {
		t.Fatalf("smux.Server() error = %v", err)
	}
	defer func() { _ = serverSess.Close() }()
	clientSess, err := smux.Client(b, smuxConfig(0))
	if err != nil {
		t.Fatalf("smux.Client() error = %v", err)
	}
	defer func() { _ = clientSess.Close() }()

	serverStreamCh := make(chan *smux.Stream, 1)
	go func() {
		stream, err := serverSess.AcceptStream()
		if err == nil {
			serverStreamCh <- stream
		}
	}()

	clientStream, err := clientSess.OpenStream()
	if err != nil {
		t.Fatalf("OpenStream() error = %v", err)
	}
	serverStream := <-serverStreamCh

	ctx, cancel := context.WithCancel(context.Background())
	got := make(chan control.Health, 1)
	s := &Server{
		sessionID: "sid-control",
		health:    runtime.NewHealthTracker(nil),
		liveness: control.Config{
			Interval: 10 * time.Millisecond,
			Timeout:  100 * time.Millisecond,
			Failures: 2,
			OnPong: func(h control.Health) {
				select {
				case got <- h:
				default:
				}
			},
		},
	}
	s.recordSession("sid-control")
	defer func() {
		cancel()
		s.wg.Wait()
	}()
	s.startControlLoop(ctx, serverSess, serverStream)
	go func() {
		_ = control.Run(ctx, clientStream, control.Config{
			Interval: 10 * time.Millisecond,
			Timeout:  100 * time.Millisecond,
			Failures: 2,
		})
	}()

	select {
	case h := <-got:
		if h.Seq == 0 {
			t.Fatal("Health.Seq = 0")
		}
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for control pong")
	}
	status := s.Status()
	if status.SessionID != "sid-control" {
		t.Fatalf("Status.SessionID = %q, want sid-control", status.SessionID)
	}
	if status.LastPong.IsZero() || status.LastRTT < 0 || status.MissedPongs != 0 {
		t.Fatalf("Status() = %+v", status)
	}
}

func TestStartControlLoopResetsPeerBeforeReinstall(t *testing.T) {
	a, b := net.Pipe()
	defer func() {
		_ = a.Close()
		_ = b.Close()
	}()

	serverSess, err := smux.Server(a, smuxConfig(0))
	if err != nil {
		t.Fatalf("smux.Server() error = %v", err)
	}
	clientSess, err := smux.Client(b, smuxConfig(0))
	if err != nil {
		t.Fatalf("smux.Client() error = %v", err)
	}

	serverStreamCh := make(chan *smux.Stream, 1)
	go func() {
		stream, err := serverSess.AcceptStream()
		if err == nil {
			serverStreamCh <- stream
		}
	}()

	clientStream, err := clientSess.OpenStream()
	if err != nil {
		t.Fatalf("OpenStream() error = %v", err)
	}
	serverStream := <-serverStreamCh

	cipher, err := cryptopkg.NewCipher("01234567890123456789012345678901")
	if err != nil {
		t.Fatalf("NewCipher() error = %v", err)
	}
	ln := &serverLinkStub{resetCh: make(chan struct{}, 1)}
	ctx, cancel := context.WithCancel(context.Background())
	s := &Server{
		ln:      ln,
		cipher:  cipher,
		conn:    muxconn.New(ln, cipher),
		session: serverSess,
		health:  runtime.NewHealthTracker(nil),
		liveness: control.Config{
			Interval: time.Hour,
			Timeout:  time.Hour,
			Failures: 1,
		},
	}
	defer func() {
		cancel()
		s.shutdown()
		s.wg.Wait()
		_ = clientSess.Close()
	}()

	s.startControlLoop(ctx, serverSess, serverStream)
	_ = clientStream.Close()

	select {
	case <-ln.resetCh:
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for ResetPeer")
	}
	if ln.resetCount != 1 {
		t.Fatalf("ResetPeer calls = %d, want 1", ln.resetCount)
	}
}

func TestStatusRecordsReconnectAndUnhealthy(t *testing.T) {
	updates := 0
	s := &Server{health: runtime.NewHealthTracker(func(control.Status) { updates++ })}
	s.recordSession("sid-1")
	s.recordMissed(2)
	s.recordUnhealthy(3)
	s.recordReconnect()

	status := s.Status()
	if status.SessionID != "sid-1" || status.MissedPongs != 3 ||
		status.UnhealthyEvents != 1 || status.Reconnects != 1 || status.LastUnhealthy.IsZero() {
		t.Fatalf("Status() = %+v", status)
	}
	if updates != 4 {
		t.Fatalf("health updates = %d, want 4", updates)
	}
}

//nolint:cyclop // integration-style test needs setup, proxying, and traffic assertions together.
func TestDispatchFiresOnTraffic(t *testing.T) {
	var lc net.ListenConfig
	ln, err := lc.Listen(context.Background(), "tcp4", testConnectAddr+":0")
	if err != nil {
		t.Fatalf("Listen() error = %v", err)
	}
	defer func() { _ = ln.Close() }()

	const greeting = "hi\n"
	go func() {
		c, err := ln.Accept()
		if err != nil {
			return
		}
		defer func() { _ = c.Close() }()
		_, _ = c.Write([]byte(greeting))
	}()

	a, b := net.Pipe()
	defer func() {
		_ = a.Close()
		_ = b.Close()
	}()

	serverSess, err := smux.Server(a, smuxConfig(0))
	if err != nil {
		t.Fatalf("smux.Server() error = %v", err)
	}
	defer func() { _ = serverSess.Close() }()
	clientSess, err := smux.Client(b, smuxConfig(0))
	if err != nil {
		t.Fatalf("smux.Client() error = %v", err)
	}
	defer func() { _ = clientSess.Close() }()

	var rec struct {
		sid     string
		addr    string
		in, out uint64
	}
	recChan := make(chan struct{})
	s := &Server{
		sessionID: "traffic-sid",
		resolver:  net.DefaultResolver,
		onTraffic: func(sid, addr string, in, out uint64) {
			rec.sid = sid
			rec.addr = addr
			rec.in = in
			rec.out = out
			close(recChan)
		},
	}

	go func() {
		stream, err := serverSess.AcceptStream()
		if err != nil {
			return
		}
		s.handleStream(context.Background(), stream, "")
	}()

	stream, err := clientSess.OpenStream()
	if err != nil {
		t.Fatalf("OpenStream() error = %v", err)
	}
	tcpAddr, ok := ln.Addr().(*net.TCPAddr)
	if !ok {
		t.Fatalf("addr type = %T", ln.Addr())
	}
	req, err := json.Marshal(ConnectRequest{
		Cmd:  testConnectCmd,
		Addr: testConnectAddr,
		Port: tcpAddr.Port,
	})
	if err != nil {
		t.Fatalf("Marshal() error = %v", err)
	}
	if _, err := stream.Write(req); err != nil {
		t.Fatalf("Write() error = %v", err)
	}

	ack := make([]byte, 1)
	if _, err := io.ReadFull(stream, ack); err != nil {
		t.Fatalf("read ack: %v", err)
	}
	body := make([]byte, len(greeting))
	if _, err := io.ReadFull(stream, body); err != nil {
		t.Fatalf("read body: %v", err)
	}
	_ = stream.Close()

	select {
	case <-recChan:
	case <-time.After(2 * time.Second):
		t.Fatal("onTraffic did not fire")
	}
	if rec.sid != "traffic-sid" {
		t.Fatalf("sid = %q, want traffic-sid", rec.sid)
	}
	if rec.out < uint64(len(greeting)) {
		t.Fatalf("bytesOut = %d, want >= %d", rec.out, len(greeting))
	}
}

func TestReinstallSessionClosesOldConnBeforeSwap(t *testing.T) {
	// Regression test: after carrier reconnect, a client that reconnects
	// faster can push smux frames into the server's old muxconn before
	// reinstallSession swaps it out. This corrupts the old smux session
	// and manifests as "frame too large" on the control stream.
	// The fix closes the old muxconn at the very start of reinstallSession
	// so Push calls during the swap window are discarded.
	cipher, err := cryptopkg.NewCipher("01234567890123456789012345678901")
	if err != nil {
		t.Fatalf("NewCipher() error = %v", err)
	}
	ln := &serverLinkStub{}
	conn := muxconn.New(ln, cipher)
	sess, err := smux.Server(conn, smuxConfig(0))
	if err != nil {
		t.Fatalf("smux.Server() error = %v", err)
	}
	s := &Server{
		ln:           ln,
		cipher:       cipher,
		conn:         conn,
		session:      sess,
		onClose:      func(string, string) {},
		health:       runtime.NewHealthTracker(nil),
		peerSessions: make(map[string]*peerSession),
	}

	// Simulate the race: push data into old conn WHILE reinstallSession
	// is running (in a separate goroutine).
	done := make(chan struct{})
	go func() {
		defer close(done)
		s.reinstallSession(sess)
	}()

	// Give reinstallSession a moment to close the old conn.
	time.Sleep(5 * time.Millisecond)

	// This simulates data arriving from a new bridge (fast-reconnecting client).
	// With the fix, Push should be a no-op (conn is already closed).
	// Without the fix, this would feed into the dying smux session.
	conn.Push([]byte("stale encrypted garbage"))

	<-done

	// Verify old conn is closed and new conn is installed.
	s.sessMu.RLock()
	newConn := s.conn
	newSess := s.session
	s.sessMu.RUnlock()

	if newConn == conn {
		t.Fatal("reinstallSession did not swap conn")
	}
	if newSess == sess {
		t.Fatal("reinstallSession did not swap session")
	}
	if newConn == nil || newSess == nil {
		t.Fatal("reinstallSession left nil conn or session")
	}
	_ = newSess.Close()
	_ = newConn.Close()
}

func TestReinstallSessionIgnoresStaleDeadSessionWithoutClosingLiveConns(t *testing.T) {
	cipher, err := cryptopkg.NewCipher("01234567890123456789012345678901")
	if err != nil {
		t.Fatalf("NewCipher() error = %v", err)
	}
	ln := &serverLinkStub{}
	liveConn := muxconn.New(ln, cipher)
	liveSess, err := smux.Server(liveConn, smuxConfig(0))
	if err != nil {
		t.Fatalf("smux.Server(live) error = %v", err)
	}
	liveControlConn := muxconn.New(ln, cipher)
	deadConn := muxconn.New(ln, cipher)
	deadSess, err := smux.Server(deadConn, smuxConfig(0))
	if err != nil {
		t.Fatalf("smux.Server(dead) error = %v", err)
	}
	defer func() {
		_ = liveSess.Close()
		_ = liveConn.Close()
		_ = liveControlConn.Close()
		_ = deadSess.Close()
		_ = deadConn.Close()
	}()
	s := &Server{
		ln:           ln,
		cipher:       cipher,
		conn:         liveConn,
		controlConn:  liveControlConn,
		session:      liveSess,
		onClose:      func(string, string) {},
		health:       runtime.NewHealthTracker(nil),
		peerSessions: make(map[string]*peerSession),
	}

	s.reinstallSession(deadSess)

	s.sessMu.RLock()
	gotConn := s.conn
	gotControlConn := s.controlConn
	gotSess := s.session
	s.sessMu.RUnlock()
	if gotConn != liveConn {
		t.Fatal("stale reinstall replaced live conn")
	}
	if gotControlConn != liveControlConn {
		t.Fatal("stale reinstall replaced live control conn")
	}
	if gotSess != liveSess {
		t.Fatal("stale reinstall replaced live session")
	}
	if _, err := liveConn.Write([]byte("live data")); err != nil {
		t.Fatalf("stale reinstall closed live conn: %v", err)
	}
	if _, err := liveControlConn.Write([]byte("live control")); err != nil {
		t.Fatalf("stale reinstall closed live control conn: %v", err)
	}
}

func TestAcceptPeerHandshakeRelatchesSameDeviceToNewPeerID(t *testing.T) {
	s := newPeerRelatchServer()
	pongCh := make(chan control.Health, 1)
	s.liveness = control.Config{
		Interval: 10 * time.Millisecond,
		Timeout:  100 * time.Millisecond,
		Failures: 2,
		OnPong: func(h control.Health) {
			select {
			case pongCh <- h:
			default:
			}
		},
	}
	old := &peerSession{
		peerID:    "00000001",
		sessionID: "sid-old",
		deviceID:  "dev-1",
	}
	ps, clientSess, cleanup := newPeerControlSession(t, "00000002")
	defer cleanup()
	defer func() {
		s.shutdown()
		s.wg.Wait()
	}()
	s.peerSessions[old.peerID] = old
	s.peerSessions[ps.peerID] = ps
	s.peerStats[old.sessionID] = peerStat{deviceID: old.deviceID, openedAt: time.Now()}

	clientStream := runPeerHandshake(t, s, ps, clientSess, "dev-1")
	controlCtx, controlCancel := context.WithCancel(context.Background())
	defer controlCancel()
	go func() {
		_ = control.Run(controlCtx, clientStream, control.Config{
			Interval: time.Hour,
			Timeout:  time.Hour,
			Failures: 2,
		})
	}()

	s.sessMu.RLock()
	gotOld := s.peerSessions[old.peerID]
	gotNew := s.peerSessions[ps.peerID]
	sessionCount := len(s.peerSessions)
	s.sessMu.RUnlock()
	if gotOld != nil {
		t.Fatal("old peerID still has a peer session")
	}
	if gotNew == nil {
		t.Fatal("new peerID has no peer session")
	}
	if sessionCount != 1 {
		t.Fatalf("peerSessions count = %d, want 1", sessionCount)
	}
	s.peersMu.Lock()
	statsCount := len(s.peerStats)
	s.peersMu.Unlock()
	if statsCount != 1 {
		t.Fatalf("peerStats count = %d, want 1", statsCount)
	}
	select {
	case h := <-pongCh:
		if h.Seq == 0 {
			t.Fatal("relatched control loop reported zero seq")
		}
	case <-time.After(time.Second):
		t.Fatal("relatched control loop did not receive pong")
	}
}

func TestAcceptPeerHandshakeDoesNotRelatchDifferentDevice(t *testing.T) {
	s := newPeerRelatchServer()
	old := &peerSession{
		peerID:    "00000001",
		sessionID: "sid-old",
		deviceID:  "dev-1",
	}
	ps, clientSess, cleanup := newPeerControlSession(t, "00000002")
	defer cleanup()
	defer func() {
		s.shutdown()
		s.wg.Wait()
	}()
	s.peerSessions[old.peerID] = old
	s.peerSessions[ps.peerID] = ps
	s.peerStats[old.sessionID] = peerStat{deviceID: old.deviceID, openedAt: time.Now()}

	_ = runPeerHandshake(t, s, ps, clientSess, "dev-2")

	s.sessMu.RLock()
	gotOld := s.peerSessions[old.peerID]
	gotNew := s.peerSessions[ps.peerID]
	sessionCount := len(s.peerSessions)
	s.sessMu.RUnlock()
	if gotOld == nil {
		t.Fatal("foreign device removed old peer session")
	}
	if gotNew == nil {
		t.Fatal("foreign device did not keep its own peer session")
	}
	if sessionCount != 2 {
		t.Fatalf("peerSessions count = %d, want 2", sessionCount)
	}
}

func TestPeerControlLivenessStillRemovesDeadSession(t *testing.T) {
	s := newPeerRelatchServer()
	ps, clientSess, cleanup := newPeerControlSession(t, "00000001")
	defer cleanup()
	defer func() {
		s.shutdown()
		s.wg.Wait()
	}()
	ps.sessionID = "sid-dead"
	ps.deviceID = "dev-dead"
	s.peerSessions[ps.peerID] = ps
	s.peerStats[ps.sessionID] = peerStat{deviceID: ps.deviceID, openedAt: time.Now()}
	s.liveness = control.Config{
		Interval: 10 * time.Millisecond,
		Timeout:  5 * time.Millisecond,
		Failures: 1,
	}

	stream, err := clientSess.OpenStream()
	if err != nil {
		t.Fatalf("OpenStream() error = %v", err)
	}
	defer func() { _ = stream.Close() }()
	serverStream, err := ps.controlSess.AcceptStream()
	if err != nil {
		t.Fatalf("AcceptStream() error = %v", err)
	}
	s.startPeerControlLoop(context.Background(), ps, serverStream)

	deadline := time.After(time.Second)
	for {
		s.sessMu.RLock()
		_, ok := s.peerSessions[ps.peerID]
		s.sessMu.RUnlock()
		if !ok {
			return
		}
		select {
		case <-deadline:
			t.Fatal("dead peer session was not removed by liveness")
		case <-time.After(10 * time.Millisecond):
		}
	}
}

func newPeerRelatchServer() *Server {
	return &Server{
		baseCtx:      context.Background(),
		authHook:     func(_ string, _ map[string]any) (string, error) { return "sid-new", nil },
		onOpen:       func(string, string, map[string]any) {},
		onClose:      func(string, string) {},
		health:       runtime.NewHealthTracker(nil),
		done:         make(chan struct{}),
		peerSessions: make(map[string]*peerSession),
		peerStats:    make(map[string]peerStat),
		liveness: control.Config{
			Interval: time.Hour,
			Timeout:  time.Hour,
			Failures: 2,
		},
	}
}

func newPeerControlSession(t *testing.T, peerID string) (*peerSession, *smux.Session, func()) {
	t.Helper()
	serverConn, clientConn := net.Pipe()
	serverSess, err := smux.Server(serverConn, controlSmuxConfig(0))
	if err != nil {
		t.Fatalf("smux.Server(control) error = %v", err)
	}
	clientSess, err := smux.Client(clientConn, controlSmuxConfig(0))
	if err != nil {
		t.Fatalf("smux.Client(control) error = %v", err)
	}
	ps := &peerSession{
		peerID:       peerID,
		controlSess:  serverSess,
		sessionReady: make(chan struct{}),
	}
	cleanup := func() {
		_ = clientSess.Close()
		_ = serverSess.Close()
		_ = clientConn.Close()
		_ = serverConn.Close()
	}
	return ps, clientSess, cleanup
}

func runPeerHandshake(
	t *testing.T,
	s *Server,
	ps *peerSession,
	clientSess *smux.Session,
	deviceID string,
) *smux.Stream {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	done := make(chan struct{})
	go func() {
		defer close(done)
		s.acceptPeerHandshake(ctx, ps)
	}()

	stream, err := clientSess.OpenStream()
	if err != nil {
		t.Fatalf("OpenStream() error = %v", err)
	}
	t.Cleanup(func() { _ = stream.Close() })
	if _, err := handshake.Client(stream, deviceID, nil); err != nil {
		t.Fatalf("handshake.Client() error = %v", err)
	}

	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("acceptPeerHandshake did not return")
	}
	return stream
}
