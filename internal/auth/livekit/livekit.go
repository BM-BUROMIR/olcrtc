// Package livekit implements local LiveKit dev auth.
package livekit

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/google/uuid"
	lkAuth "github.com/livekit/protocol/auth"

	"github.com/openlibrecommunity/olcrtc/internal/auth"
)

const (
	// DevAPIKey is the local LiveKit dev API key used by deploy/livekit.yaml.
	DevAPIKey = "devkey"
	// DevAPISecret is the local LiveKit dev API secret used by deploy/livekit.yaml.
	DevAPISecret = "devsecret"
	// DefaultURL is the local LiveKit signaling URL exposed by deploy/docker-compose.livekit.yaml.
	DefaultURL = "ws://127.0.0.1:7880"

	tokenTTL = 24 * time.Hour
)

// Provider produces LiveKit credentials for the local Docker dev server.
type Provider struct{}

// Engine reports which engine consumes credentials from this auth provider.
// ai-generated: local LiveKit provider engine binding.
func (Provider) Engine() string { return "livekit" }

// DefaultServiceURL returns the local LiveKit signaling URL.
// ai-generated: local LiveKit provider default service URL.
func (Provider) DefaultServiceURL() string { return DefaultURL }

// Issue signs a local LiveKit room token with Docker dev keys.
// ai-generated: local LiveKit token issuing flow.
func (Provider) Issue(_ context.Context, cfg auth.Config) (auth.Credentials, error) {
	roomID := strings.TrimSpace(cfg.RoomURL)
	if roomID == "" || roomID == "any" {
		return auth.Credentials{}, auth.ErrRoomIDRequired
	}

	token, err := roomToken(roomID, identity(cfg.Name))
	if err != nil {
		return auth.Credentials{}, err
	}
	return auth.Credentials{
		URL:   DefaultURL,
		Token: token,
		Extra: map[string]string{"roomID": roomID},
	}, nil
}

// CreateRoom returns a local room ID; LiveKit creates it on first join.
// ai-generated: local LiveKit room ID creation.
func (Provider) CreateRoom(_ context.Context, cfg auth.Config) (string, error) {
	if roomID := strings.TrimSpace(cfg.Name); roomID != "" {
		return roomID, nil
	}
	return "local-" + uuid.NewString(), nil
}

// ai-generated: helper that signs a local LiveKit JWT with room permissions.
func roomToken(roomID, participant string) (string, error) {
	grant := &lkAuth.VideoGrant{
		RoomCreate: true,
		RoomJoin:   true,
		Room:       roomID,
	}
	grant.SetCanPublish(true)
	grant.SetCanPublishData(true)
	grant.SetCanSubscribe(true)
	token, err := lkAuth.NewAccessToken(DevAPIKey, DevAPISecret).
		SetIdentity(participant).
		SetName(participant).
		SetValidFor(tokenTTL).
		SetVideoGrant(grant).
		ToJWT()
	if err != nil {
		return "", fmt.Errorf("sign livekit token: %w", err)
	}
	return token, nil
}

// ai-generated: helper that normalizes local LiveKit participant identity.
func identity(name string) string {
	name = strings.TrimSpace(name)
	if name == "" {
		return "olcrtc-local"
	}
	return name
}

// ai-generated: local LiveKit auth registration.
func init() { //nolint:gochecknoinits // auth registration is the canonical Go pattern for plugins
	auth.Register("livekit", Provider{})
}
