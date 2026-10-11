# Ruru

Read `Documentation/ARCHITECTURE.md` first. This is a separate native macOS app
and lease authority, not a SwiftBot bot/worker and not a root Swift package.

- Ruru's long-term direction is a general, capability-based service coordinator.
  Read `Documentation/COORDINATION.md` before extending coordination features.
  Keep shared identities and contracts application-neutral; add app-specific
  behavior through focused Swift capability modules. Lease guarding is the first
  capability, and new work must preserve its safety and resource bounds.

- Support macOS 15 (Sequoia), Intel x86_64 and Apple silicon arm64. The initial
  deployment is a 2012 Intel Mac mini with OpenCore, 16 GB RAM, in Invercargill.
- Read `Documentation/DESIGN.md` before UI changes. Match SwiftBot’s current
  console headers, sidebar, surfaces, service cards, and spacing while supporting Sequoia.
- Use SwiftUI and Apple system frameworks. Avoid macOS 26-only UI APIs,
  Apple Intelligence and third-party UI libraries. Application-owned code must
  be Swift; prefer Swift dependency APIs, with native engine wrappers allowed.
  DuckDB uses the official Swift package pinned in `project.yml`.
- Sparkle mirrors SwiftMiner's pinned 2.9.5 integration. ShipHook owns release
  signing, publishing and appcast items. Only its public Ed25519 key belongs in
  app configuration; never generate/export a release private key locally.
  Updates remain disabled while that public key is missing.
- `project.yml` is the XcodeGen source of truth. Run `xcodegen` after changes.
- Build/test with Xcode, never root `swift build` or `swift test`:
  `xcodebuild -project Ruru.xcodeproj -scheme Ruru build`
  `xcodebuild -project Ruru.xcodeproj -scheme Ruru test`
- Verify a Release universal binary before claiming Intel support.
- Preserve SwiftBot's `/v1/lease/acquire|renew|release` JSON protocol.
- `RuruClient` is the supported public SwiftPM integration boundary. When Ruru
  adds or changes a client-facing capability, update its typed client API,
  documentation and conformance coverage in the same change. Preserve existing
  public API and wire compatibility unless a deliberately versioned breaking
  release is approved; keep app-specific workflows out of the package.
- Terms never decrease; expired renewals never revive ownership. Persist before
  acknowledging grants. Clock expiry must be monotonic, with a full lease
  quarantine after process restart. Never silently replace a damaged database.
- One authority process owns one database. Keep the lifetime file lock.
- Secrets belong in Keychain. Never log bearer tokens or export bot credentials.
- Closing the window must leave the menu bar service running. Do not enable
  login registration, alter power settings, or deploy a tunnel without a request.
- Keep tests isolated from real Keychain, login items, and production storage.
- Update `Documentation/ROADMAP.md` with completed work and validation limits.
