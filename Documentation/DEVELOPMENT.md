# Development

Ruru is a native macOS app with a reusable `WitnessKit` framework. Application-owned runtime code is Swift 6. DuckDB's official Swift package wraps a native C++ engine; the optional Cloudflare connector is a bundled upstream helper.

Read [architecture](ARCHITECTURE.md) before changing authority behaviour and [design](DESIGN.md) before changing the UI. The app targets macOS 15.0. The project was validated with Xcode 27; compiling the Icon Composer asset requires a version of Xcode that supports `.icon` files.

## Open and build

Install XcodeGen, then run from the repository root:

```sh
xcodegen
open Ruru.xcodeproj
xcodebuild -project Ruru.xcodeproj -scheme Ruru -configuration Debug build
xcodebuild -project Ruru.xcodeproj -scheme Ruru \
  -configuration Debug -parallel-testing-enabled NO test
xcodebuild -project Ruru.xcodeproj -scheme Ruru \
  -configuration Release ONLY_ACTIVE_ARCH=NO build
```

`project.yml` is the source of truth. Run `xcodegen` after changes to targets, dependencies, resources, or build settings. This is not a root Swift package; use Xcode to build and test.

Xcode resolves DuckDB Swift at the pinned version **1.1.3** and Sparkle **2.9.5**, matching SwiftMiner. The connector is already vendored in `Resources/cloudflared`. The app does not download database extensions or require a package manager at runtime. `Scripts/vendor_cloudflared.py` is a maintenance tool, not part of the app runtime.

## Tests and preview

Tests use temporary storage and injected credentials. The test-only `WitnessStorageProbe` verifies recovery after killing an authority process immediately after an acknowledged grant. It is not bundled in the app.

Run the application with `--preview` to inspect the native console without creating Keychain data, opening a listener, or registering a login item:

```sh
open /path/to/Ruru.app --args --preview
```

For Preferred Primary UI checks, add `--preview-primary-preference` alongside
`--preview`. This supplies two static, in-memory observed server fixtures and an
existing owner; choosing, clearing or cancelling updates only the preview's
metadata. It opens no database, listener or Keychain. The Preferred Primary
image uses this fixture rather than a live workload.

The screenshot in the README shows this preview, not a live authority. Sparkle is disabled in preview mode, including network checks and preference writes. Do not enable login registration, alter power settings, or deploy a tunnel as part of development verification.

## Updates

`AppUpdater.swift` adapts SwiftMiner's Sparkle integration. ShipHook owns the
release private key and publishing; this app needs only its public Ed25519 key.
`SPARKLE_PUBLIC_ED_KEY` is intentionally empty until ShipHook supplies it, so
development builds show updates as unavailable. Never substitute a developer's
local key or disable signature validation to make updates appear enabled.

Run the read-only built-bundle preflight after building:

```sh
swift Scripts/validate_sparkle.swift /path/to/Ruru.app --allow-unconfigured
```

Omit `--allow-unconfigured` for release validation; it then rejects a missing
public key. The script checks generated Info.plist values, embedded Sparkle and
the source feeds, and rejects unsigned/malformed published items. It does not
sign, publish, contact ShipHook or prove that a live archive signature is valid.

## App icon

`ruru.icon` is the original Icon Composer source. Xcode compiles it into the app's icon resources, including the fallback used by macOS 15. The README image is exported from that compiled icon. Keep the original Composer asset as the source of truth.

## Signing

Local builds use ad-hoc signing with hardened runtime. `Configuration/Development.entitlements` permits loading the ad-hoc embedded framework. Before public distribution, sign the app and its embedded code with a shared Developer ID team and remove that development entitlement from the distribution configuration. See the [release guide](RELEASING.md).
