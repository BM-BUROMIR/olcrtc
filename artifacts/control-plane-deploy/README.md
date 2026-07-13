# Control-plane deployment artifact

The deployed Linux probe is reproducible from the repository:

```bash
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -trimpath \
  -o artifacts/control-plane-deploy/olcrtc-linux-amd64 ./cmd/olcrtc
```

- Go source revision: `55b6622a896effe4cbd80bf6c9f5c682c5c304ab`
- Target: `linux/amd64`, static executable
- SHA-256: `64f69f72ffdc5b38cd09c09a6a66ea0f56aa32c08d66381887bdebf3189cdc77`
- First durable deployment revision: `269b209f0ea08601dceeb0d38624dda04ddbbd10`

The binary remains in this directory for cross-session reuse but is intentionally not committed.
Credentials, provider payloads, host addresses, and restored databases belong only in the private
runtime tree outside this repository checkout.
