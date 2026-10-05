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

Xcode resolves DuckDB Swift at the pinned version **1.1.3**. The connector is already vendored in `Resources/cloudflared`. The app does not download database extensions or require a package manager at runtime. `Scripts/vendor_cloudflared.py` is a maintenance tool, not part of the app runtime.

## Tests and preview

Tests use temporary storage and injected credentials. The test-only `WitnessStorageProbe` verifies recovery after killing an authority process immediately after an acknowledged grant. It is not bundled in the app.

Run the application with `--preview` to inspect the native console without creating Keychain data, opening a listener, or registering a login item:

```sh
open /path/to/Ruru.app --args --preview
```

The screenshot in the README shows this preview, not a live authority. Do not enable login registration, alter power settings, or deploy a tunnel as part of development verification.

## App icon

`ruru.icon` is the original Icon Composer source. Xcode compiles it into the app's icon resources, including the fallback used by macOS 15. The README image is exported from that compiled icon. Keep the original Composer asset as the source of truth.

## Signing

Local builds use ad-hoc signing with hardened runtime. `Configuration/Development.entitlements` permits loading the ad-hoc embedded framework. Before public distribution, sign the app and its embedded code with a shared Developer ID team and remove that development entitlement from the distribution configuration. See the [release guide](RELEASING.md).
