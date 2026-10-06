# Preparing a release

The planned GitHub repository is **johnwatso/ruru**. **ShipHook owns release
signing, notarisation, publishing and appcast items.** We do not own or export
its private Sparkle signing key. Public assets are not yet published. Version
**0.2.0** is a development preview; ShipHook provisioning, actual Intel execution,
target-Mac resource measurements and a complete paired-bot failure drill remain outstanding.

## ShipHook and Sparkle handoff

Ruru embeds Sparkle **2.9.5**, matching SwiftMiner, with these publishing inputs:

- Xcode project/scheme: `Ruru.xcodeproj` / `Ruru`, configuration `Release`.
- Bundle identifier: `com.swiftmesh.witness`; product: `Ruru.app`.
- Stable source feed: `docs/appcast.xml`, served at
  `https://johnwatso.github.io/ruru/appcast.xml`.
- Beta source feed: `docs/beta/appcast.xml`, served at
  `https://johnwatso.github.io/ruru/beta/appcast.xml`.
- Feed hosting: configure GitHub Pages to serve the publishing repository's
  `docs/` folder, or an equivalent deployment preserving those URLs.
- Minimum macOS: `15.0`; application, WitnessKit and connector are universal.
- `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` come from `project.yml`.
- Background checks default on; automatic downloads default off.

Before the first release, obtain **only ShipHook's public Ed25519 key** and set
`SPARKLE_PUBLIC_ED_KEY` in `project.yml`, regenerate the project, and build with
that exact key. ShipHook can instead supply a build-setting override, provided
the override is recorded and verified in the shipped app. The source setting is
intentionally empty until the publisher supplies it; such builds disable updates.
Do not use a local developer key, copy SwiftMiner's embedded key, or disable
signature verification. The feed files are empty until ShipHook publishes a real
release; do not create an enclosure for the local development ZIP.

ShipHook must sign the **final distributed archive** and include its
`sparkle:edSignature`, exact byte length, archive URL and shipped bundle build
number in the corresponding appcast item. For beta items, the app accepts the
`beta` Sparkle channel. ShipHook must make both the archive and feed reachable
over HTTPS. Updating a source feed alone does not publish it.

Run the read-only preflight against the finished app:

```sh
swift Scripts/validate_sparkle.swift /path/to/Ruru.app
```

The preflight rejects missing public keys, generated-plist/version drift,
missing embedded Sparkle and unsigned/malformed published items. It checks
structure; ShipHook and an actual update installation must verify the final
archive signature. Use `--allow-unconfigured` only for development validation.

## Build and validate

1. Update `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`, run `xcodegen`, and review the release notes.
2. Run the Xcode tests and build Release for both architectures:

   ```sh
   xcodebuild -project Ruru.xcodeproj -scheme Ruru \
     -configuration Debug -parallel-testing-enabled NO test
   xcodebuild -project Ruru.xcodeproj -scheme Ruru \
     -configuration Release ONLY_ACTIVE_ARCH=NO \
     -derivedDataPath /tmp/ruru-release build
   ```

3. Verify the app, `WitnessKit.framework`, and `cloudflared` each contain **x86_64 and arm64** with a minimum macOS version of **15.0**. Check the generated `ruru.icns` fallback and launch an isolated `--preview`.
4. Verify behaviour on the Intel Sequoia/OpenCore deployment Mac. Complete Primary loss, recovery, authority loss, restart quarantine, and network-partition drills with paired bots before describing that revision as deployment-validated.

## Distribution signing

ShipHook must configure a Developer ID Application identity and team for the
app, frameworks and helpers, including Sparkle's nested executables and XPC
services. Override the app's `CODE_SIGN_ENTITLEMENTS` with
`Configuration/Distribution.entitlements`, which omits development
library-validation relaxation, without removing any
upstream entitlements needed by Sparkle helpers. The repository's
`Configuration/Development.entitlements` is only for ad-hoc development builds.
ShipHook signs all embedded code, notarises the distribution and staples the
ticket. Verify the finished app with `codesign --verify --deep --strict` and
Gatekeeper before publishing.

The current local ZIP is an ad-hoc development export and must not be described as notarised.

## Package

Package directly from a clean build directory, rather than a loose app copied into a synced folder. Finder metadata added to a copied bundle can invalidate strict signature checks.

```sh
mkdir -p Build/Release
ditto -c -k --sequesterRsrc --keepParent \
  /tmp/ruru-release/Build/Products/Release/Ruru.app Build/Release/Ruru.zip
shasum -a 256 Build/Release/Ruru.zip
```

Extract the ZIP into a fresh temporary directory and repeat signature, architecture, minimum-OS, and icon checks. Confirm the archive contains only the app, its dependencies, licences, and resources. Never include a database, user settings, Keychain exports, or credentials.

## GitHub release

Once distribution validation is complete, ShipHook publishes a versioned tag
and archive to [GitHub Releases](https://github.com/johnwatso/ruru/releases), with
the SHA-256 checksum and release notes, then publishes the matching signed
appcast enclosure. Keep the README's installation instructions and preview
status accurate when the first public build is available.

Verify the actual hosted feed and archive against the shipped app, including a
manual update from an older build and automatic-download/install-on-quit flow.
An update may briefly interrupt authority service; verify listener/connector
shutdown, preserved terms and restart quarantine. Checking for updates must not
restart the authority. Do not claim automatic updates work before this test.

Release notes should explain the Ruru rename, DuckDB storage, macOS 15 minimum, universal architecture support, and the absence of SQLite migration. Existing SQLite authorities must be replaced offline with a new cluster configuration; link to [ownership and storage](STORAGE.md).

Update [the development log](ROADMAP.md) with completed validation and remaining limits. Preparing this repository does not publish a release or modify a live authority.
