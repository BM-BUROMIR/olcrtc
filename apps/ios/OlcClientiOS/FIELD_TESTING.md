# OlcClient iOS: field testing

## Built-in profiles

The app reads optional built-in profiles from:

```text
App/BuiltInProfiles.local.json
```

This file is generated locally and ignored by git. It is bundled into the `.ipa`, so the app can start with
Telemost/WB choices without pasting JSON on the device.

Generate it before building:

```bash
cd whitelist-bypass/client/ios/OlcClientiOS
OLC_WB_SRV_YAML=/path/to/wb-srv.yaml scripts/generate-local-profiles.rb
xcodegen generate
```

Inputs:

- Telemost defaults to `../../../.secrets/olc-stand/telemost-subscription.json`.
- WB can be supplied as `OLC_WB_SUBSCRIPTION_JSON=/path/to/wb-subscription.json` or
  `OLC_WB_SRV_YAML=/path/to/wb-srv.yaml`.

The generator prints only profile count/output path; it must not print subscription values.

## Quick install on your own device

Use this for the current private test loop.

```bash
cd whitelist-bypass/client/ios/OlcClientiOS
xcodegen generate
xcodebuild \
  -project OlcClientiOS.xcodeproj \
  -scheme OlcClientiOS \
  -destination 'platform=iOS,id=<DEVICE_UDID>' \
  -allowProvisioningUpdates \
  build
```

The same flow also works from Xcode: open `OlcClientiOS.xcodeproj`, select the connected device, then Run.

Device checklist:

- The device is trusted on the Mac.
- The Apple Developer team used by `DEVELOPMENT_TEAM` can sign both the app and Packet Tunnel extension.
- The device is registered in the developer account or can be registered by Xcode automatic signing.
- App Group and Network Extension entitlements are present in the provisioning profiles.

On a new install or after deleting the VPN configuration, iOS will ask for permission to add the VPN
configuration. A normal app cannot bypass that prompt. Installing over the existing app/config usually
preserves the already approved VPN configuration.

## More convenient distribution

For a small fixed list of personal devices, export an Ad Hoc `.ipa` with all UDIDs registered in the
provisioning profile. For broader field testing, use TestFlight after the Network Extension entitlement and
profiles are correct in App Store Connect.

Both options still require the first-run iOS VPN permission prompt on each device.
