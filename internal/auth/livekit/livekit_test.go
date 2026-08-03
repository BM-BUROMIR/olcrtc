package livekit

import (
	"context"
	"errors"
	"testing"

	lkAuth "github.com/livekit/protocol/auth"

	"github.com/openlibrecommunity/olcrtc/internal/auth"
)

// ai-generated: test for local LiveKit provider defaults and signed room token grants.
func TestProviderIssueSignsRoomToken(t *testing.T) {
	const roomID = "local-room"

	creds, err := (Provider{}).Issue(context.Background(), auth.Config{
		RoomURL: roomID,
		Name:    "alice",
	})
	if err != nil {
		t.Fatalf("Issue() error = %v", err)
	}
	if creds.URL != DefaultURL {
		t.Fatalf("Issue() URL = %q, want %q", creds.URL, DefaultURL)
	}
	if creds.Extra["roomID"] != roomID {
		t.Fatalf("Issue() roomID extra = %q, want %q", creds.Extra["roomID"], roomID)
	}

	verifyLiveKitToken(t, creds.Token, "alice", roomID)
}

// ai-generated: test that local LiveKit provider rejects empty room IDs.
func TestProviderIssueRequiresRoomID(t *testing.T) {
	_, err := (Provider{}).Issue(context.Background(), auth.Config{})
	if !errors.Is(err, auth.ErrRoomIDRequired) {
		t.Fatalf("Issue() error = %v, want %v", err, auth.ErrRoomIDRequired)
	}
}

// ai-generated: test that local LiveKit room creation returns a usable room ID.
func TestProviderCreateRoom(t *testing.T) {
	roomID, err := (Provider{}).CreateRoom(context.Background(), auth.Config{Name: "room-from-gen"})
	if err != nil {
		t.Fatalf("CreateRoom() error = %v", err)
	}
	if roomID != "room-from-gen" {
		t.Fatalf("CreateRoom() = %q, want %q", roomID, "room-from-gen")
	}
}

// ai-generated: helper that verifies the generated JWT grant through LiveKit verifier.
func verifyLiveKitToken(t *testing.T, token, identity, roomID string) {
	t.Helper()

	verifier, err := lkAuth.ParseAPIToken(token)
	if err != nil {
		t.Fatalf("ParseAPIToken() error = %v", err)
	}
	if verifier.APIKey() != DevAPIKey {
		t.Fatalf("APIKey() = %q, want %q", verifier.APIKey(), DevAPIKey)
	}
	if verifier.Identity() != identity {
		t.Fatalf("Identity() = %q, want %q", verifier.Identity(), identity)
	}

	_, grants, err := verifier.Verify(DevAPISecret)
	if err != nil {
		t.Fatalf("Verify() error = %v", err)
	}
	requireVideoGrant(t, grants.Video, roomID)
}

// ai-generated: helper that verifies LiveKit video grants for local auth.
func requireVideoGrant(t *testing.T, grant *lkAuth.VideoGrant, roomID string) {
	t.Helper()

	if grant == nil {
		t.Fatal("Video grant is nil")
	}
	if !grant.RoomJoin {
		t.Fatal("RoomJoin grant = false, want true")
	}
	if !grant.RoomCreate {
		t.Fatal("RoomCreate grant = false, want true")
	}
	if grant.Room != roomID {
		t.Fatalf("Video room = %q, want %q", grant.Room, roomID)
	}
	if !grant.GetCanPublishData() {
		t.Fatal("CanPublishData = false, want true")
	}
	if !grant.GetCanPublish() {
		t.Fatal("CanPublish = false, want true")
	}
	if !grant.GetCanSubscribe() {
		t.Fatal("CanSubscribe = false, want true")
	}
}
