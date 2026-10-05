# Ruru

Read `Documentation/ARCHITECTURE.md` first. This is a separate native macOS app
and lease authority, not a SwiftBot bot/worker and not a root Swift package.

- Support macOS 15 (Sequoia), Intel x86_64 and Apple silicon arm64. The initial
  deployment is a 2012 Intel Mac mini with OpenCore, 16 GB RAM, in Invercargill.
- Read `Documentation/DESIGN.md` before UI changes. Match SwiftBot’s current
  console headers, sidebar, surfaces, service cards, and spacing while supporting Sequoia.
- Use SwiftUI and Apple system frameworks. Avoid macOS 26-only UI APIs,
  Apple Intelligence and third-party UI libraries. Application-owned code must
  be Swift; prefer Swift dependency APIs, with native engine wrappers allowed.
  DuckDB uses the official Swift package pinned in `project.yml`.
- `project.yml` is the XcodeGen source of truth. Run `xcodegen` after changes.
- Build/test with Xcode, never root `swift build` or `swift test`:
  `xcodebuild -project Ruru.xcodeproj -scheme Ruru build`
  `xcodebuild -project Ruru.xcodeproj -scheme Ruru test`
- Verify a Release universal binary before claiming Intel support.
- Preserve SwiftBot's `/v1/lease/acquire|renew|release` JSON protocol.
- Terms never decrease; expired renewals never revive ownership. Persist before
  acknowledging grants. Clock expiry must be monotonic, with a full lease
  quarantine after process restart. Never silently replace a damaged database.
- One authority process owns one database. Keep the lifetime file lock.
- Secrets belong in Keychain. Never log bearer tokens or export bot credentials.
- Closing the window must leave the menu bar service running. Do not enable
  login registration, alter power settings, or deploy a tunnel without a request.
- Keep tests isolated from real Keychain, login items, and production storage.
- Update `Documentation/ROADMAP.md` with completed work and validation limits.
