#!/usr/bin/env sh
set -eu

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

if ! command -v gitleaks >/dev/null 2>&1; then
  echo "gitleaks not found; install https://github.com/gitleaks/gitleaks before committing" >&2
  exit 127
fi

fail=0

added_lines() {
  {
    git show --format= --no-ext-diff HEAD 2>/dev/null || true
    git diff --cached --no-ext-diff --binary
    git diff --no-ext-diff --binary
  } | awk '/^\+\+\+ / { next } /^\+/ { sub(/^\+/, ""); print }'
}

scan_added() {
  name="$1"
  pattern="$2"
  if added_lines | grep -E -q "$pattern"; then
    echo "secret check failed: $name" >&2
    fail=1
  fi
}

scan_added "local absolute path" '/Users/[A-Za-z0-9._-]+/|/home/[A-Za-z0-9._-]+/|/[p]rivate/var/|/var/[f]olders/|/Volumes/[A-Za-z0-9._-]+/'
scan_added "GitHub or chat token" 'gh[opsu]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[baprs]-[A-Za-z0-9-]{20,}'
scan_added "private key marker" 'BEGIN (RSA|OPENSSH|EC|DSA|PRIVATE) KEY|END (RSA|OPENSSH|EC|DSA|PRIVATE) KEY'

if added_lines | grep -E -q 'olcrtc://[^[:space:]"<>]+#[0-9a-fA-F]{64}'; then
  echo "secret check failed: embedded olcrtc URI key outside docs" >&2
  fail=1
fi

if ! added_lines | gitleaks stdin --redact --no-banner; then
  fail=1
fi

exit "$fail"
