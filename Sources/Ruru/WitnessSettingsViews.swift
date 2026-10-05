import SwiftUI
import WitnessKit

struct WitnessSettingsPage: View {
    @EnvironmentObject private var model: WitnessAppModel
    @State var configuration: WitnessConfiguration
    @State private var launchAtLogin = false
    @State private var saving = false
    @State private var error: String?
    @State private var feedback: String?
    private var changed: Bool { configuration != model.configuration || launchAtLogin != model.launchAtLogin }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ConsolePageHeader(title: "Settings", subtitle: "Preferences for this witness Mac.") {
                    HStack(spacing: 10) {
                        Button("Revert", action: reset).buttonStyle(.bordered).buttonBorderShape(.capsule)
                            .disabled(!changed || saving)
                        Button(saving ? "Saving…" : "Save Changes") { Task { await save() } }
                            .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                            .disabled(!changed || !configuration.isValid || saving || model.busy || model.internetBusy)
                            .keyboardShortcut("s", modifiers: .command)
                    }
                }
                if let error { ConsoleIssue(title: "Settings could not be saved", detail: error) }
                ConsoleSection("Appearance") {
                    ConsoleSettingRow(title: "Show in Dock", subtitle: "Show Ruru’s app icon in the Dock as well as the menu bar.") {
                        Toggle("Show in Dock", isOn: $configuration.showInDock).toggleStyle(.switch).labelsHidden()
                    }.consoleRowGroup()
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
                ConsoleSection("Startup") {
                    VStack(spacing: 0) {
                        ConsoleSettingRow(title: "Start the service automatically", subtitle: "Start the ownership listener when this app opens.") {
                            Toggle("Start the service automatically", isOn: $configuration.startAutomatically)
                                .toggleStyle(.switch).labelsHidden()
                        }
                        Divider().padding(.leading, 16)
                        ConsoleSettingRow(title: "Launch at login", subtitle: "Keep the witness available after signing in to this Mac.") {
                            Toggle("Launch at login", isOn: $launchAtLogin).toggleStyle(.switch).labelsHidden()
                        }
                    }.consoleRowGroup()
                    if model.loginNeedsApproval {
                        ConsoleIssue(title: "Login item needs approval", detail: "Approve Ruru in System Settings → General → Login Items.")
                    }
                }
                ConsoleSection("Connection") {
                    VStack(spacing: 0) {
                        if !model.configuration.primaryServiceRemoved {
                            ConsoleSettingRow(title: "Cluster ID", subtitle: "The original SwiftBot service’s ownership group. Additional services are managed in Guarding.") {
                                TextField("Cluster ID", text: $configuration.clusterID)
                                    .textFieldStyle(.roundedBorder).frame(width: 220)
                            }
                            Divider().padding(.leading, 16)
                        }
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
                            TextField("Public HTTPS endpoint", text: $configuration.publicEndpoint, prompt: Text("https://witness.example.com"))
                                .textFieldStyle(.roundedBorder).frame(width: 280)
                                .disabled(configuration.tunnel.isConfigured)
                        }
                    }.consoleRowGroup()
                    Text(configuration.tunnel.isConfigured
                        ? "Internet Access manages the public endpoint and local listener."
                        : "Use Internet Access to create a Cloudflare tunnel, or enter an existing HTTPS endpoint.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ConsoleSection("About") {
                    VStack(spacing: 0) {
                        ConsoleValueRow(title: "Application", value: "Ruru")
                        Divider().padding(.leading, 16)
                        ConsoleValueRow(title: "Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2.0")
                        Divider().padding(.leading, 16)
                        ConsoleValueRow(title: "Build", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—")
                    }.consoleRowGroup()
                }
                if let feedback { Label(feedback, systemImage: "checkmark.circle").font(.callout).foregroundStyle(.secondary) }
                Text("Changes apply when you save. Closing the window leaves the witness running in the menu bar.")
                    .font(.callout).foregroundStyle(.secondary)
            }.padding(.horizontal, 36).padding(.top, 32).padding(.bottom, 40)
                .frame(maxWidth: 1120, alignment: .leading).frame(maxWidth: .infinity)
                .disabled(saving)
        }
        .onAppear { model.refreshLoginStatus(); launchAtLogin = model.launchAtLogin }
    }

    private func reset() {
        configuration = model.configuration
        launchAtLogin = model.launchAtLogin
        error = nil; feedback = nil
    }
    private func save() async {
        saving = true; error = nil; feedback = nil
        defer { saving = false }
        do {
            try await model.saveConfiguration(configuration)
            if launchAtLogin != model.launchAtLogin { await model.setLaunchAtLogin(launchAtLogin) }
            configuration = model.configuration
            launchAtLogin = model.launchAtLogin
            feedback = "Settings saved."
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
                ? "Enter these values in SwiftMesh → Recovery and Pairing on every participating SwiftBot."
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
        }.frame(width: 640, height: 470).background(WitnessGlassBackground())
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
    @State var hostname: String
    @State private var apiToken = ""
    @State private var error: String?
    var body: some View {
        VStack(spacing: 0) {
            WitnessSheetHeader(title: "Cloudflare Internet Access", subtitle: "Give this witness its own address. The app sets up DNS, HTTPS access, and the tunnel.", symbol: "globe")
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ConsoleSection("Cloudflare") {
                        VStack(spacing: 0) {
                            ConsoleSettingRow(title: "Hostname", subtitle: "Choose an unused subdomain.") {
                                TextField("Hostname", text: $hostname, prompt: Text("witness.example.com"))
                                    .textFieldStyle(.roundedBorder).frame(width: 270)
                                    .disabled(model.configuration.tunnel.isConfigured)
                            }
                            Divider().padding(.leading, 16)
                            ConsoleSettingRow(title: "API token", subtitle: model.configuration.tunnel.isConfigured ? "Leave blank to use the saved token." : "Saved to Keychain after verification.") {
                                SecureField("Cloudflare API token", text: $apiToken).textFieldStyle(.roundedBorder).frame(width: 270)
                            }
                        }.consoleRowGroup().disabled(model.internetBusy)
                    }
                    ConsoleSection("API Permissions") {
                        VStack(spacing: 0) {
                            ConsoleValueRow(title: "Zone", value: "Zone → Read\nDNS → Edit")
                            Divider().padding(.leading, 16)
                            ConsoleValueRow(title: "Account", value: "Cloudflare Tunnel → Edit")
                        }.consoleRowGroup()
                        HStack {
                            Text("Scope the token to your domain and account.").font(.callout).foregroundStyle(.secondary)
                            Spacer()
                            Link("Create API Token", destination: URL(string: "https://dash.cloudflare.com/profile/api-tokens")!)
                                .font(.callout)
                        }
                    }
                    if model.internetBusy {
                        HStack { ProgressView().controlSize(.small); Text(model.internetProgress).font(.callout) }
                    }
                    if let error { ConsoleIssue(title: "Setup could not be completed", detail: error) }
                }.padding(.horizontal, 24).padding(.bottom, 24)
            }
            Divider()
            HStack {
                Text("A separate tunnel for this witness.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.internetBusy)
                Button(model.internetBusy ? "Setting Up…" : "Connect") { connect() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(WitnessInternetSetup.normalizedHostname(hostname) == nil || model.internetBusy || model.busy
                        || (!model.configuration.tunnel.isConfigured && apiToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }.controlSize(.large).padding(20)
        }.frame(width: 680, height: 610).background(WitnessGlassBackground())
            .interactiveDismissDisabled(model.internetBusy)
    }

    private func connect() {
        error = nil
        Task {
            do {
                try await model.setupInternetAccess(hostname: hostname, tokenDraft: apiToken)
                apiToken = ""
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}
