# iOS TestFlight automation

This directory contains the private iOS TestFlight pipeline wrapper for the local OLC iOS app.

The tracked files contain no Apple private keys and no machine-local paths. Keep all App Store
Connect credentials outside git and point the wrapper to them with `OLC_APPSTORE_ENV`.

`portal_prepare` is the only command in this directory that changes the Apple Developer portal/App
Store Connect app setup. Run it intentionally; the other commands work with local files,
certificates, profiles, builds or TestFlight upload.

## Commands

```sh
script/ios-testflight.sh doctor
script/ios-testflight.sh dry_run
OLC_APPSTORE_ENV=/path/to/local/env script/ios-testflight.sh portal_prepare
OLC_APPSTORE_ENV=/path/to/local/env script/ios-testflight.sh certificates
OLC_APPSTORE_ENV=/path/to/local/env script/ios-testflight.sh profiles
script/ios-testflight.sh archive
OLC_APPSTORE_ENV=/path/to/local/env script/ios-testflight.sh beta
```

`doctor` checks local TestFlight readiness. `dry_run` applies bundle identifiers, regenerates the
Xcode project and runs an unsigned generic iOS build. `portal_prepare` creates or updates App Store
Connect app records and Bundle IDs with the ASC API key. When `OLC_APPLE_ID` is set, it also runs
the legacy Apple Developer portal App Group create/associate steps and may require interactive Apple
2FA. `certificates` ensures an Apple Distribution certificate exists locally. `profiles`
creates/downloads App Store provisioning profiles for the app and packet tunnel targets through a
curl-based ASC API flow by default. Set `OLC_IOS_USE_FASTLANE_SIGH=1` to fall back to fastlane
`sigh`. `archive` builds an App Store archive and IPA. `beta` builds and uploads the IPA to
TestFlight.

`archive` and `beta` rebuild `OlcMobile.xcframework` with stripped Go symbols and trim paths from a
neutral build root, then reject the framework if it contains the repository path, home directory,
or temporary paths. This requires `gomobile` in `PATH` and prevents developer-machine paths from
shipping in the IPA.

## Default Apple identifiers

| Setting | Default |
|---|---|
| app bundle id | `com.oxi717.olc` |
| packet tunnel bundle id | `com.oxi717.olc.tunnel` |
| app group | `group.com.oxi717.olc` |

These defaults match the existing personal Apple account namespace used by the mobile projects in
the adjacent workspace. The Apple Developer account still must have matching App IDs, App Group and
Network Extension capability/provisioning for both targets.

## Local env file

Copy `olc.env.example` to a private location outside git and fill in the values:

```sh
OLC_APPSTORE_ENV=/path/to/local/env script/ios-testflight.sh beta
```

The wrapper auto-detects the adjacent local iOS app in the usual repo and worktree layouts. Override
`OLC_IOS_APP_DIR` only when running from a different checkout. The wrapper also supports overriding
identifiers through the env file. For normal private testing leave the defaults in place.

By default the lane requires built-in `telemost` and `wb` profiles. Set
`OLC_TELEMOST_SUBSCRIPTION_JSON` and `OLC_WB_SRV_YAML` or `OLC_WB_SUBSCRIPTION_JSON` in the private
env file when the local generator cannot discover them. To override the requirement, set
`OLC_REQUIRED_BUILTIN_PROFILES` to a comma-separated profile id list.

For a fully local signing path, keep `OLC_IOS_SIGNING_STYLE=manual` in the private env after
`certificates` and `profiles` have succeeded. The generated Xcode project is then switched to the
named App Store profiles before archive/export. Without manual signing, Xcode automatic signing
needs a valid signed-in Apple account in Xcode.

`certificates` may write `.p12` signing material. Set `OLC_IOS_CERTIFICATE_OUTPUT_DIR` to a private
directory when you want those files retained; otherwise they are written to the ignored local build
cache.

If `doctor` reports that installed provisioning profiles lack the App Group or Network Extension
entitlement, the Bundle IDs exist but the Apple Developer portal has not associated the concrete App
Group/capability with those IDs. Set `OLC_APPLE_ID` and rerun `portal_prepare`, or do the association
manually in the Apple Developer portal, then rerun `OLC_IOS_FORCE_PROFILES=1 ... profiles`.

## Expected manual Apple steps

Apple may still require one-time setup that fastlane cannot complete with the ASC API key alone:

- set `OLC_APPLE_ID` and run `portal_prepare` once, or create the App Store app record and
  create/associate the App Group manually;
- answer encryption/export compliance questions for TestFlight;
- add the Apple ID used on the device to internal testers.

iOS will also ask for permission to add the VPN configuration on first run.
