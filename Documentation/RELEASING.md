# Preparing a release

The planned GitHub repository is **johnwatso/ruru**. Public assets are not yet published. Version **0.2.0** is a development preview; signing, notarisation, actual Intel execution, target-Mac resource measurements, and a complete paired-bot failure drill remain outstanding.

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

Configure a Developer ID Application identity and team for the app, framework, and helper. Remove `Configuration/Development.entitlements` from the distribution signing configuration; it is only for ad-hoc development builds. Sign all embedded code, notarise the distribution with Apple's service, and staple the ticket. Verify the finished app with `codesign --verify --deep --strict` and Gatekeeper before publishing.

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

Once distribution validation is complete, publish a versioned tag and `Ruru.zip` to [GitHub Releases](https://github.com/johnwatso/ruru/releases), with the SHA-256 checksum and release notes. Keep the README's installation instructions and preview status accurate when the first public build is available.

Release notes should explain the Ruru rename, DuckDB storage, macOS 15 minimum, universal architecture support, and the absence of SQLite migration. Existing SQLite authorities must be replaced offline with a new cluster configuration; link to [ownership and storage](STORAGE.md).

Update [the development log](ROADMAP.md) with completed validation and remaining limits. Preparing this repository does not publish a release or modify a live authority.
