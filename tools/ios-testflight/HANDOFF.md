# iOS TestFlight handoff - 2026-07-08

## Scope

Work on branch `ios-testflight-automation` in `BM-BUROMIR/olcrtc`.

Hard rules:

- do not open an upstream PR or post upstream comments without owner approval;
- do not push this private work to `origin`;
- do not commit Apple private keys, tokens, `.p8`, `.p12`, `.mobileprovision`,
  generated profile JSON/YAML, real room data or local absolute paths;
- do not use `gh auth switch` for routine commands. Several GitHub accounts are
  used in parallel on the same machine.

## Verified state

Commit `fbf4f08` adds the private TestFlight automation:

- `script/ios-testflight.sh`;
- `tools/ios-testflight/README.md`;
- `tools/ios-testflight/olc.env.example`;
- `tools/ios-testflight/apply_identifiers.rb`;
- `tools/ios-testflight/fastlane/Fastfile`.

Default Apple identifiers:

| Setting | Value |
|---|---|
| app bundle id | `com.oxi717.olc` |
| packet tunnel bundle id | `com.oxi717.olc.tunnel` |
| app group | `group.com.oxi717.olc` |
| app display name | `OLC` |

Verified commands on 2026-07-08:

```sh
go test ./...
git diff --check
git diff --cached --check
sh -n script/ios-testflight.sh
ruby -c tools/ios-testflight/apply_identifiers.rb
ruby -c tools/ios-testflight/fastlane/Fastfile
script/secrets-check.sh
OLC_APPSTORE_ENV=<private-env> script/ios-testflight.sh dry_run
```

All commands above passed.

`certificates` and `profiles` were also run successfully with the private env.
The App Store provisioning profiles are installed locally, but `doctor` still
fails on Apple portal entitlements:

```text
TestFlight preflight failed:
- installed provisioning profile for com.oxi717.olc lacks app group or network extension entitlement
- installed provisioning profile for com.oxi717.olc.tunnel lacks app group or network extension entitlement
```

The current `doctor` requires each installed profile to contain both:

- `com.apple.security.application-groups` with `group.com.oxi717.olc`;
- `com.apple.developer.networking.networkextension` with `packet-tunnel-provider`.

## Apple portal fix

First try the semi-automatic path if an interactive Apple ID session is allowed:

```sh
OLC_APPSTORE_ENV=<private-env> OLC_APPLE_ID=<apple-id-email> script/ios-testflight.sh portal_prepare
OLC_APPSTORE_ENV=<private-env> OLC_IOS_FORCE_PROFILES=1 script/ios-testflight.sh profiles
OLC_APPSTORE_ENV=<private-env> script/ios-testflight.sh doctor
```

If `portal_prepare` cannot associate the App Group or create the App Store app
record, do the Apple portal steps manually:

1. Open Apple Developer - Certificates, Identifiers & Profiles - Identifiers.
2. Ensure App Group `group.com.oxi717.olc` exists.
3. Open App ID `com.oxi717.olc`.
4. Enable App Groups and select `group.com.oxi717.olc`.
5. Enable Network Extensions and select Packet Tunnel.
6. Save.
7. Open App ID `com.oxi717.olc.tunnel`.
8. Enable App Groups and select `group.com.oxi717.olc`.
9. Enable Network Extensions and select Packet Tunnel.
10. Save.
11. In App Store Connect, ensure an iOS app record exists for bundle
    `com.oxi717.olc`, SKU `olc-private`, display name `OLC`.

After portal changes, always recreate profiles. Existing profiles keep the old
entitlement payload.

```sh
OLC_APPSTORE_ENV=<private-env> OLC_IOS_FORCE_PROFILES=1 script/ios-testflight.sh profiles
OLC_APPSTORE_ENV=<private-env> script/ios-testflight.sh doctor
```

Expected `doctor` result after the Apple fix: no `TestFlight preflight failed`
message, and printed values for app bundle id, tunnel bundle id, app group and
signing style.

Then continue:

```sh
OLC_APPSTORE_ENV=<private-env> script/ios-testflight.sh archive
OLC_APPSTORE_ENV=<private-env> script/ios-testflight.sh beta
```

## GitHub auth without global switching

For this repo, push to `bm`, never `origin`.

Use a per-command token for the required GitHub account. Do not change the
global active `gh` account.

```sh
export GH_TOKEN="$(gh auth token --hostname github.com --user BM-BUROMIR)"
GIT_TERMINAL_PROMPT=0 git \
  -c credential.helper= \
  -c credential.https://github.com.helper='!f() { test "$1" = get || exit 0; echo username=x-access-token; echo "password=$GH_TOKEN"; }; f' \
  push bm HEAD:ios-testflight-automation
unset GH_TOKEN
```

This exact push form was verified after restoring the global active account to
the previous user. The remote returned `Everything up-to-date`.
