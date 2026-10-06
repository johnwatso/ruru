# Release notes

## 0.2.0 — Unreleased development preview

- Introduces **Ruru**, the new name for SwiftMesh Witness, with the owl app icon.
- Renames the Xcode project, application target, and scheme to `Ruru`.
- Replaces SQLite runtime storage with DuckDB through the official Swift package.
- Keeps the existing SwiftMesh JSON lease protocol, durable terms, restart
  quarantine, lifetime database locking, and fail-closed storage behaviour.
- Adds **Guarding**, with independent service ownership groups, separate Keychain
  credentials, service connection details, known servers and scoped activity.
- Supports additional SwiftBot groups and other apps using the lease protocol,
  with no two-participant limit within a service.
- Shows readable server names scoped to each service.
- Adds per-service Preferred Primary selection, clearing and a scoped read-only
  policy API. Current ownership remains independent; coordinated return requires
  compatible client support.
- Adds removal for every service, retaining ownership terms/history and supporting an empty catalog.
- Adds a saved **Show in Dock** option alongside the background menu bar service.
- Adds Sparkle 2.9.5, Stable/Beta update channels, background-check and automatic
  download preferences, and Check for Updates in Settings and both menus.
  Activation awaits ShipHook's public signing key and published feeds.
- Aligns Overview with SwiftBot's app-icon summary, adaptive service cards,
  lifecycle controls, Quick Actions and read-only System panel.
- Adds explicit **Set Up DuckDB** to archive SQLite storage and create fresh pairing details.
- Retains built-in Cloudflare Internet Access and the background menu bar service.
- Targets macOS 15.0 or later with universal Intel and Apple silicon Release builds.

Bundle identifiers, Keychain accounts, settings paths and tunnel identities are
preserved. **SQLite data is not migrated.** Existing authority storage prevents
startup from silently creating fresh ownership terms. Replace an old authority
only while every participating client is stopped and unpaired, then use a new cluster
configuration; see [ownership and storage](Documentation/STORAGE.md).

Current builds are signed for development. Distribution signing, notarisation,
actual Intel execution, target-Mac measurements and the complete paired-bot
failover drill remain outstanding. See [the development log](Documentation/ROADMAP.md)
for the recorded validation.
