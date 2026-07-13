# Control-plane deployment artifact

The deployed Linux probe is reproducible from the repository:

```bash
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -trimpath \
  -ldflags='-s -w' \
  -o artifacts/control-plane-deploy/olcrtc-linux-amd64 ./cmd/olcrtc
```

- Go source revision: `6f85efa245d9b5de79f79ce7996470541268ef3b`
- Target: `linux/amd64`, static executable
- SHA-256: `739a9fa45d39b1c481486226dcfe4d1597312161c0e0a0b30b39d18071b3b88f`
- First durable deployment revision: `269b209f0ea08601dceeb0d38624dda04ddbbd10`

The binary remains in this directory for cross-session reuse but is intentionally not committed.
Credentials, provider payloads, host addresses, and restored databases belong only in the private
runtime tree outside this repository checkout.
