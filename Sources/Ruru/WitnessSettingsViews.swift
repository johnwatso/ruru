import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WitnessKit

struct WitnessSettingsView: View {
    @EnvironmentObject private var model: WitnessAppModel
    @EnvironmentObject private var updater: AppUpdater
    @EnvironmentObject private var diagnostics: RuruDiagnosticExportSession
    @Environment(\.openWindow) private var openWindow
    /// Mirrors the saved preferences; each edit is applied immediately.
    @State var configuration: WitnessConfiguration
    private enum Pane: String, CaseIterable, Identifiable {
        case general = "General", alerts = "Alerts", updates = "Updates", backup = "Backup"
        var id: Self { self }
        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .alerts: "bell"
            case .updates: "arrow.clockwise.circle"
            case .backup: "externaldrive"
            }
        }
    }
    @State private var pane: Pane = .general
    @State private var launchAtLogin = false
    @State private var error: String?
    @State private var pendingSave: Task<Void, Never>?
    @State private var updateChannel: AppUpdater.UpdateChannel = .stable
    @State private var automaticChecks = false
    @State private var automaticDownloads = false

    var body: some View {
        TabView(selection: $pane) {
            ForEach(Pane.allCases) { pane in
                paneContent(for: pane)
                    .tabItem { Label(pane.rawValue, systemImage: pane.symbol) }
                    .tag(pane)
            }
        }.frame(width: 540)
            .onAppear { model.refreshLoginStatus(); reset() }
            .onChange(of: configuration.showInDock) { applyPreferences() }
            .onChange(of: configuration.startAutomatically) { applyPreferences() }
            .onChange(of: configuration.alerts) { applyPreferences() }
            .onChange(of: model.configuration.alerts) { _, value in configuration.alerts = value }
            .onChange(of: launchAtLogin) { _, value in applyLaunchAtLogin(value) }
            .onChange(of: model.launchAtLogin) { _, value in launchAtLogin = value }
            .onChange(of: updateChannel) { applyUpdatePreferences() }
            .onChange(of: automaticChecks) { applyUpdatePreferences() }
            .onChange(of: automaticDownloads) { applyUpdatePreferences() }
            .onChange(of: updater.automaticallyChecksForUpdates) { _, value in automaticChecks = value }
            .onChange(of: updater.automaticallyDownloadsUpdates) { _, value in automaticDownloads = value }
    }

    @ViewBuilder private func paneContent(for pane: Pane) -> some View {
        Form {
            switch pane {
            case .general: generalSettings
            case .alerts: WitnessAlertSettings(preferences: $configuration.alerts)
            case .updates: updateSettings
            case .backup: WitnessBackupSettings()
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var generalSettings: some View {
        Section {
            Picker(selection: $configuration.showInDock) {
                Label("Dock + Menu Bar", systemImage: "menubar.dock.rectangle").tag(true)
                Label("Menu Bar", systemImage: "menubar.rectangle").tag(false)
            } label: {
                Text("Show Ruru in")
                Text(configuration.showInDock
                     ? "Keep Ruru easy to reach from both the Dock and the menu bar."
                     : "Keep Ruru out of the Dock and control it from the menu bar.")
            }
        } footer: {
            Text("Ruru keeps running in the menu bar when its window is closed.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        Section {
            Toggle(isOn: $configuration.startAutomatically) {
                Text("Start service when Ruru opens")
                Text("Begins listening for ownership requests at launch.")
            }
            Toggle(isOn: $launchAtLogin) {
                Text("Open at login")
                Text("Keeps the authority available after you sign in to this Mac.")
            }
            if model.loginNeedsApproval {
                warning("Approve Ruru in System Settings → General → Login Items.")
            }
        } header: {
            Text("Startup")
        }
        Section {
            LabeledContent {
                Button(diagnostics.isPreparing ? "Preparing…" : "Export Report…") {
                    // The exporter is hosted by the main window so it always has
                    // a reliable presenting window, including in menu-bar mode.
                    openWindow(id: "witness")
                    NSApplication.shared.activate()
                    diagnostics.begin(model: model)
                }
                .disabled(diagnostics.isPreparing || diagnostics.isExporterPresented)
            } label: {
                Text("Diagnostic report")
                Text("Save a redacted authority and lease-state report for troubleshooting.")
            }
        } footer: {
            Text("Reports exclude credentials, endpoints, URLs and raw error text. They use Ruru’s existing bounded ownership history and current observations only.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        if let error {
            Section { warning("Settings could not be saved: " + error) }
        }
    }

    @ViewBuilder private var updateSettings: some View {
        Section {
            Picker(selection: $updateChannel) {
                ForEach(AppUpdater.UpdateChannel.allCases) { channel in
                    Text(channel.label).tag(channel)
                }
            } label: {
                Text("Update channel")
                Text(updateChannel == .beta
                     ? "Beta releases may contain unfinished changes."
                     : "Stable is recommended for an ownership authority.")
            }
            Toggle(isOn: $automaticChecks) {
                Text("Automatically check for updates")
                Text("Shows a prompt when a new version is available.")
            }
            Toggle(isOn: $automaticDownloads) {
                Text("Automatically download updates")
                Text("Installs downloaded updates when Ruru quits.")
            }.disabled(!automaticChecks)
        } footer: {
            updateFooter
        }.disabled(!updater.canCheckForUpdates)
        Section {
            LabeledContent {
                Button("Check Now") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            } label: {
                Text("Last checked")
                Text(updater.lastCheckDate?.formatted(date: .abbreviated, time: .shortened) ?? "Never")
            }
            if let error = updater.error { warning(error) }
        } footer: {
            Text("Installing an update can briefly interrupt ownership service. Restart quarantine still applies.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var updateFooter: some View {
        if updater.isPreview {
            Text("Update checks are disabled in this preview.").font(.footnote).foregroundStyle(.secondary)
        } else if !updater.isConfigured {
            Text("Updates will be available once release publishing is configured.").font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func warning(_ text: String) -> some View {
        Label {
            Text(text).textSelection(.enabled)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    private func reset() {
        configuration = model.configuration
        launchAtLogin = model.launchAtLogin
        updateChannel = updater.selectedChannel
        automaticChecks = updater.automaticallyChecksForUpdates
        automaticDownloads = updater.automaticallyDownloadsUpdates
    }

    /// Saves are serialised and always write the latest values, so quick
    /// successive edits cannot race the model's single-save guard.
    private func applyPreferences() {
        let previous = pendingSave
        pendingSave = Task {
            await previous?.value
            let saved = model.configuration
            guard configuration.alerts != saved.alerts || configuration.showInDock != saved.showInDock ||
                  configuration.startAutomatically != saved.startAutomatically else { return }
            // Save only application preferences, preserving connection edits made
            // in the console while this window is open.
            var draft = saved
            draft.showInDock = configuration.showInDock
            draft.alerts = configuration.alerts
            draft.startAutomatically = configuration.startAutomatically
            do {
                try await model.saveConfiguration(draft)
                error = nil
            } catch {
                self.error = error.localizedDescription
                configuration.showInDock = model.configuration.showInDock
                configuration.alerts = model.configuration.alerts
                configuration.startAutomatically = model.configuration.startAutomatically
            }
        }
    }

    private func applyLaunchAtLogin(_ enabled: Bool) {
        guard enabled != model.launchAtLogin, !updater.isPreview else { return }
        Task {
            await model.setLaunchAtLogin(enabled)
            // Registration can fail or need approval; show the real state.
            launchAtLogin = model.launchAtLogin
        }
    }

    private func applyUpdatePreferences() {
        updater.apply(channel: updateChannel, automaticChecks: automaticChecks,
                      automaticDownloads: automaticDownloads)
    }
}

/// Operational connection controls live with Internet Access, outside Preferences.
struct WitnessConnectionSettingsSheet: View {
    @EnvironmentObject private var model: WitnessAppModel
    @Environment(\.dismiss) private var dismiss
    @State var configuration: WitnessConfiguration
    @State private var saving = false
    @State private var error: String?

    private var changed: Bool {
        configuration.bindAddress != model.configuration.bindAddress ||
        configuration.port != model.configuration.port ||
        configuration.publicEndpoint != model.configuration.publicEndpoint
    }

    var body: some View {
        VStack(spacing: 0) {
            WitnessSheetHeader(title: "Connection Settings", subtitle: "Configure this authority’s listener and HTTPS endpoint.", symbol: "network")
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    connectionSettings
                    if let error { ConsoleIssue(title: "Connection could not be saved", detail: error) }
                }.padding(.horizontal, 24).padding(.bottom, 24)
            }
            Divider()
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(saving ? "Saving…" : "Save Connection") { Task { await save() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!changed || !configuration.isValid || saving || model.busy || model.internetBusy)
            }.padding(20)
        }.frame(width: 700, height: 600).background(WitnessGlassBackground()).disabled(saving)
    }

    @ViewBuilder private var connectionSettings: some View {
        ConsoleSection("Connection") {
            VStack(spacing: 0) {
                ConsoleSettingRow(title: "Local listener", subtitle: "Cloudflare uses the listener on this Mac.") {
                    Picker("Local listener", selection: $configuration.bindAddress) {
                        Text("This Mac only").tag("127.0.0.1")
                        Text("All IPv4 interfaces").tag("0.0.0.0")
                        Text("This Mac only (IPv6)").tag("::1")
                    }.labelsHidden().frame(width: 220).disabled(configuration.tunnel.isConfigured)
                }
                Divider().padding(.leading, 16)
                ConsoleSettingRow(title: "Port") {
                    TextField("Port", value: $configuration.port, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder).frame(width: 100)
                        .disabled(configuration.tunnel.isConfigured)
                }
                Divider().padding(.leading, 16)
                ConsoleSettingRow(title: "Public HTTPS endpoint") {
                    TextField("Public HTTPS endpoint", text: $configuration.publicEndpoint, prompt: Text("https://ruru.example.com"))
                        .textFieldStyle(.roundedBorder).frame(width: 280)
                        .disabled(configuration.tunnel.isConfigured)
                }
            }.consoleRowGroup()
            Text(configuration.tunnel.isConfigured
                ? "Internet Access manages the public endpoint and local listener."
                : "Use Internet Access to create a Cloudflare tunnel, or enter an existing HTTPS endpoint.")
                .font(.callout).foregroundStyle(.secondary)
        }
        if model.legacyStorageNeedsReplacement {
            ConsoleSection("Storage") { WitnessLegacyStorageNotice() }
        }
        if let archive = model.storageArchivePath {
            ConsoleSection("Storage") {
                Text("Old SQLite storage was archived. Re-pair every remaining service using its new connection details.")
                    .font(.callout).foregroundStyle(.secondary)
                Text(archive).font(.caption).textSelection(.enabled)
            }
        }
    }

    private func save() async {
        saving = true
        error = nil
        defer { saving = false }
        do {
            guard configuration.tunnel == model.configuration.tunnel else {
                throw WitnessStorage.ConfigurationError.invalid
            }
            // Preserve General preferences saved in the separate Settings window.
            var saved = model.configuration
            saved.bindAddress = configuration.bindAddress
            saved.port = configuration.port
            saved.publicEndpoint = configuration.publicEndpoint
            try await model.saveConfiguration(saved)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct WitnessSheetHeader: View {
    let title: String
    let subtitle: String
    let symbol: String
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ConsoleIconTile(symbol: symbol, size: 44)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.title2.weight(.semibold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }.padding(24)
    }
}

struct ConnectionDetailsSheet: View {
    @EnvironmentObject private var model: WitnessAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var feedback: String?
    var clusterID: String? = nil
    private var service: GuardedService? {
        if let clusterID { return model.service(for: clusterID) }
        return model.configuration.guardedServices.first
    }
    var body: some View {
        if let service {
        VStack(spacing: 0) {
            WitnessSheetHeader(title: "Connect " + service.name, subtitle: service.kind == .swiftBot
                ? "Create a pairing code below and enter it in SwiftBot’s SwiftMesh → Recovery and Pairing → Set Up Ruru."
                : "Configure this app’s participating servers with these ownership connection details.", symbol: "link")
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ConsoleSection("Connection Details") {
                        VStack(spacing: 0) {
                            ConsoleValueRow(title: "HTTPS endpoint", value: model.configuration.publicEndpoint.isEmpty ? "Configure Internet Access first" : model.configuration.publicEndpoint)
                            Divider().padding(.leading, 16)
                            ConsoleValueRow(title: "Cluster ID", value: service.clusterID, monospaced: true)
                            Divider().padding(.leading, 16)
                            ConsoleSettingRow(title: "Bearer token", subtitle: "Stored securely in this Mac’s Keychain.") {
                                Button("Copy Token", systemImage: "key") { model.copyToken(clusterID: service.clusterID); feedback = "Bearer token copied." }
                                    .buttonStyle(.bordered).disabled(!model.hasCredential(for: service.clusterID))
                            }
                        }.consoleRowGroup()
                    }
                    Text("The bearer token grants access only to this service’s ownership group. Cloudflare credentials stay on this Mac.")
                        .font(.callout).foregroundStyle(.secondary)
                    WitnessPairingPanel(service: service)
                    if let feedback { Label(feedback, systemImage: "checkmark.circle").font(.callout).foregroundStyle(.secondary) }
                }.padding(.horizontal, 24).padding(.bottom, 24)
            }
            Divider()
            HStack {
                Button("Copy All Details", systemImage: "doc.on.doc") {
                    model.copyConnectionDetails(clusterID: service.clusterID); feedback = "Connection details copied, including the bearer token."
                }.buttonStyle(.bordered).disabled(model.configuration.publicEndpoint.isEmpty || !model.hasCredential(for: service.clusterID))
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }.controlSize(.large).padding(20)
        }.frame(width: 640, height: 640).background(WitnessGlassBackground())
        } else {
            VStack(spacing: 20) {
                ConsoleEmptyState(symbol: "checkmark.shield", title: "No service selected", detail: "Add a service in Guarding to get its connection details.")
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }.padding(24).frame(width: 500).background(WitnessGlassBackground())
        }
    }
}

struct WitnessInternetSheet: View {
    @EnvironmentObject private var model: WitnessAppModel
    @Environment(\.dismiss) private var dismiss
    /// Kept for call-site compatibility; the address is chosen from the token’s domains.
    init(hostname: String) {}

    var body: some View {
        VStack(spacing: 0) {
            WitnessSheetHeader(title: "Cloudflare Internet Access",
                               subtitle: "Give Ruru its own HTTPS address. It sets up the DNS record and tunnel for you.", symbol: "globe")
            ScrollView {
                RuruCloudflareConnect().padding(.horizontal, 24).padding(.bottom, 24)
            }
            Divider()
            HStack {
                Text("A separate tunnel for this Ruru.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).disabled(model.internetBusy)
            }.controlSize(.large).padding(20)
        }.frame(width: 640, height: 600).background(WitnessGlassBackground())
            .interactiveDismissDisabled(model.internetBusy)
    }
}

/// Snapshots, export and disaster restore. Lease state is never restored as-is:
/// every term is raised and the authority stays quarantined for a full lease.
private struct WitnessBackupSettings: View {
    @EnvironmentObject private var model: WitnessAppModel
    @State private var message: String?
    @State private var failure: String?
    @State private var pending: WitnessAppModel.BackupContents?
    @State private var working = false

    var body: some View {
        Section {
            LabeledContent {
                HStack {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [WitnessStorage.snapshotFiles().last ?? WitnessStorage.snapshotsDirectory])
                    }.disabled(model.lastSnapshotDate == nil)
                    Button("Snapshot Now") { Task { await model.takeSnapshot() } }
                        .disabled(!model.backupAvailable || model.busy)
                }
            } label: {
                Text("Last snapshot")
                Text(model.lastSnapshotDate?.formatted(date: .abbreviated, time: .shortened) ?? "None yet")
            }
            if let error = model.snapshotError { warning(error) }
        } header: {
            Text("Automatic Snapshots")
        } footer: {
            footnote("Ruru saves ownership terms and history once a day and keeps the last \(WitnessStorage.snapshotsKept). Snapshots and settings are included in Time Machine; the live ownership database is not, because restoring an older copy could reissue terms.")
        }
        Section {
            LabeledContent {
                Button("Export…", action: export)
            } label: {
                Text("Backup file")
                Text("Services, names, policies, settings, and current terms.")
            }
            LabeledContent {
                Button("Restore…", action: chooseRestore)
            } label: {
                Text("Restore from backup")
                Text("Rebuilds ownership from a backup or snapshot with raised terms.")
            }
            if let message { Label(message, systemImage: "checkmark.circle").foregroundStyle(.secondary) }
            if let failure { warning(failure) }
        } header: {
            Text("Backup and Restore")
        } footer: {
            footnote("Bearer tokens and Cloudflare credentials are never exported. After restoring on a new Mac, pair each server again and set up Internet Access.")
        }
        .disabled(!model.backupAvailable || working || model.busy)
        .sheet(item: Binding(get: { pending.map(PendingRestore.init) }, set: { pending = $0?.contents })) { item in
            WitnessRestoreSheet(contents: item.contents) { includeSettings in
                pending = nil
                Task { await restore(item.contents, includeSettings: includeSettings) }
            }.environmentObject(model)
        }
    }

    private struct PendingRestore: Identifiable {
        let contents: WitnessAppModel.BackupContents
        var id: URL { contents.url }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Ruru Backup \(Date().formatted(.iso8601.year().month().day())).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        working = true; message = nil; failure = nil
        Task {
            defer { working = false }
            do {
                try await model.exportBackup(to: url)
                message = "Backup exported."
            } catch { failure = error.localizedDescription }
        }
    }

    private func chooseRestore() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.directoryURL = WitnessStorage.snapshotsDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        message = nil; failure = nil
        do { pending = try model.readBackup(at: url) }
        catch { failure = error.localizedDescription }
    }

    private func restore(_ contents: WitnessAppModel.BackupContents, includeSettings: Bool) async {
        working = true
        defer { working = false }
        do {
            try await model.restoreBackup(contents, includeSettings: includeSettings)
            message = "Restored. Ruru is stopped and will wait 30 seconds after starting before granting ownership."
        } catch { failure = error.localizedDescription }
    }

    private func footnote(_ text: String) -> some View {
        Text(text).font(.footnote).foregroundStyle(.secondary)
    }

    private func warning(_ text: String) -> some View {
        Label {
            Text(text).textSelection(.enabled)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }
}

private struct WitnessRestoreSheet: View {
    @Environment(\.dismiss) private var dismiss
    let contents: WitnessAppModel.BackupContents
    let restore: (Bool) -> Void
    @State private var includeSettings = true
    @State private var previousStopped = false
    @State private var understood = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    LabeledContent("Created", value: contents.createdAt?.formatted(date: .abbreviated, time: .shortened) ?? "Unknown")
                    if let leases = contents.leases {
                        LabeledContent("Ownership", value: "\(leases.leases.count) services · highest term \(leases.highestTerm)")
                    } else {
                        LabeledContent("Ownership", value: "Not included")
                    }
                    if let configuration = contents.configuration {
                        Toggle(isOn: $includeSettings) {
                            Text("Restore settings")
                            Text("Replaces services, names, policies, and preferences with the backup’s \(configuration.guardedServices.count) services. Internet Access stays as it is.")
                        }
                    }
                } header: {
                    Text("Restore \(contents.url.lastPathComponent)")
                } footer: {
                    if contents.leases != nil {
                        Text("Ruru stops the service, archives the current ownership database, and rebuilds it from this backup with every term raised by \(LeaseRestore.termMargin.formatted()). No server can be granted a term it has already seen. Ownership is not restored; after you start Ruru, it waits a full lease before granting.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if contents.leases != nil {
                    Section {
                        Toggle("Any other Ruru authority for these services is stopped", isOn: $previousStopped)
                        Toggle("Servers may need to acquire ownership again", isOn: $understood)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Restore") { restore(contents.configuration != nil && includeSettings) }
                    .buttonStyle(.borderedProminent)
                    .disabled(contents.leases != nil && !(previousStopped && understood)
                              || contents.leases == nil && !(contents.configuration != nil && includeSettings))
            }.padding(16)
        }.frame(width: 500)
    }
}

/// What Ruru reports and where. Changes apply immediately like other settings;
/// the Discord webhook URL is stored in Keychain, never in settings.
private struct WitnessAlertSettings: View {
    @EnvironmentObject private var model: WitnessAppModel
    @Binding var preferences: RuruAlertPreferences
    @State private var settingUpDiscord = false
    @State private var settingUpNotify = false
    @State private var sending = false
    @State private var failure: String?

    var body: some View {
        Section {
            Toggle(isOn: $preferences.serviceDown) {
                Text("A service goes down")
                Text("Its owner stops renewing and no other server takes over within 15 seconds.")
            }
            Toggle(isOn: $preferences.failover) {
                Text("A service fails over")
                Text("Ownership moves to another server without a planned release.")
            }
            Toggle(isOn: $preferences.authorityProblems) {
                Text("Ruru has a problem")
                Text("The listener stops, Internet Access drops, or a snapshot can’t be saved.")
            }
            Toggle(isOn: $preferences.participantStatus) {
                Text("A participant reports a power or session change")
                Text("UPS power loss, low battery, restored power, or a planned session end.")
            }
            Toggle(isOn: $preferences.operationalStatus) {
                Text("Operational readiness or failover protection changes")
                Text("SwiftBot-reported readiness and Ruru-observed standby protection changes.")
            }
        } header: {
            Text("Alert Me When")
        } footer: {
            Text("Ruru also tells you when each problem is resolved. Participant status alerts are opt-in. Planned releases, stopping the service, and the wait after a restart never alert.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        Section {
            Toggle("macOS notifications", isOn: $preferences.notifications)
            if model.discordConfigured {
                Toggle(isOn: $preferences.discord) {
                    Text("Discord")
                    Text("Posts to the saved webhook.")
                }
                LabeledContent("Webhook") {
                    HStack {
                        Button("Replace…") { settingUpDiscord = true }
                        Button("Remove", role: .destructive) {
                            Task {
                                do { try await model.removeDiscordWebhook() }
                                catch { failure = error.localizedDescription }
                            }
                        }
                    }
                }
            } else {
                LabeledContent {
                    Button("Set Up…") { settingUpDiscord = true }
                } label: {
                    Text("Discord")
                    Text("Post alerts to a channel with a webhook.")
                }
            }
            if model.notifyConfigured {
                Toggle(isOn: $preferences.notify) {
                    Text("Notify!")
                    Text("Sends alerts to the saved device or group.")
                }
                LabeledContent("Notify! destination") {
                    HStack {
                        Text(model.configuration.notifyID).foregroundStyle(.secondary)
                        Button("Replace…") { settingUpNotify = true }
                        Button("Remove", role: .destructive) {
                            Task {
                                do { try await model.removeNotifyDestination() }
                                catch { failure = error.localizedDescription }
                            }
                        }
                    }
                }
            } else {
                LabeledContent {
                    Button("Set Up…") { settingUpNotify = true }
                } label: {
                    Text("Notify!")
                    Text("Send alerts to a Notify! device or group.")
                }
            }
            LabeledContent {
                Button(sending ? "Sending…" : "Send Test") {
                    sending = true
                    Task { await model.sendTestAlert(); sending = false }
                }.disabled(sending || !(preferences.notifications || model.discordConfigured || model.notifyConfigured))
            } label: {
                Text("Test")
                Text("Sends one alert to each destination.")
            }
            if let error = failure ?? model.alertDeliveryError { warning(error) }
        } header: {
            Text("Deliver To")
        }
        .disabled(!model.backupAvailable)
        .sheet(isPresented: $settingUpDiscord) { WitnessDiscordSetupSheet().environmentObject(model) }
        .sheet(isPresented: $settingUpNotify) { WitnessNotifySetupSheet().environmentObject(model) }
    }

    private func warning(_ text: String) -> some View {
        Label {
            Text(text).textSelection(.enabled)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }
}

private struct WitnessNotifySetupSheet: View {
    @EnvironmentObject private var model: WitnessAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var id = ""
    @State private var token = ""
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Device or group ID", text: $id)
                    SecureField("Token", text: $token)
                    if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                } header: {
                    Text("Notify! Destination")
                } footer: {
                    Text("Copy the ID and token from the Notify! app. Ruru verifies them before saving; the token stays in macOS Keychain. Test sends one sample notification.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped).scrollDisabled(true).fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(saving ? "Verifying…" : "Save") {
                    saving = true
                    Task {
                        do { try await model.setNotifyDestination(id: id, token: token); dismiss() }
                        catch { self.error = error.localizedDescription; saving = false }
                    }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(RuruNotify.validID(id) == nil || RuruNotify.validToken(token) == nil || saving)
            }.padding(16)
        }.frame(width: 480)
    }
}

struct WitnessDiscordSetupSheet: View {
    @EnvironmentObject private var model: WitnessAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    SecureField("Webhook URL", text: $url, prompt: Text("https://discord.com/api/webhooks/…"))
                    if let error { Text(error).foregroundStyle(.red) }
                } header: {
                    Text("Discord Webhook")
                } footer: {
                    Text("In Discord, open the channel’s settings → Integrations → Webhooks → New Webhook, then Copy Webhook URL. Ruru keeps it in Keychain. Alerts include a description, service and server names, a reported Web UI address where relevant, and a timestamp.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped).scrollDisabled(true).fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(saving ? "Saving…" : "Save") {
                    saving = true
                    Task {
                        do { try await model.setDiscordWebhook(url); dismiss() }
                        catch { self.error = error.localizedDescription; saving = false }
                    }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(RuruDiscordWebhook.validated(url) == nil || saving)
            }.padding(16)
        }.frame(width: 480)
    }
}
