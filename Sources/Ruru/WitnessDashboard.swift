import SwiftUI
import WitnessKit

enum WitnessPage: String, CaseIterable, Identifiable {
    case overview = "Overview", guarding = "Guarding", coordination = "Coordination", internet = "Internet Access", activity = "Activity"
    var id: Self { self }
    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .guarding: "checkmark.shield"
        case .coordination: "square.stack.3d.up"
        case .internet: "globe"
        case .activity: "clock.arrow.circlepath"
        }
    }
}

struct WitnessDashboard: View {
    @EnvironmentObject private var model: WitnessAppModel
    private var selection: WitnessPage? { model.selectedPage }
    @State private var visibility: NavigationSplitViewVisibility = .all
    @State private var showInternet = false
    @State private var confirmingStop = false

    var body: some View {
        NavigationSplitView(columnVisibility: $visibility) {
            WitnessSidebar(selection: $model.selectedPage)
                .navigationSplitViewColumnWidth(min: 200, ideal: 200, max: 200)
        } detail: {
            GeometryReader { geometry in
                destination
                    .id(selection ?? .overview)
                    .padding(.top, visibility == .detailOnly ? 36 : 0)
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                    .background(WitnessGlassBackground())
                    .clipped()
            }.ignoresSafeArea(.container, edges: .top)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 900, minHeight: 640)
        .sheet(isPresented: $showInternet) { WitnessInternetSheet(hostname: model.configuration.tunnel.hostname).environmentObject(model) }
        .sheet(isPresented: $model.showingSetup) { RuruSetupAssistant().environmentObject(model) }
        .confirmationDialog("Stop the Ruru service?", isPresented: $confirmingStop) {
            Button("Stop Service", role: .destructive) { Task { await model.stop() } }
        } message: {
            Text("Participating apps lose access to Ruru and stop acting when their current ownership permission expires.")
        }
    }

    @ViewBuilder private var destination: some View {
        switch selection ?? .overview {
        case .overview:
            WitnessOverview(onNavigate: { model.selectedPage = $0 }, onStop: { confirmingStop = true })
        case .guarding:
            WitnessGuardingPage()
        case .coordination:
            WitnessCoordinationPage()
        case .internet:
            WitnessInternetPage(onSetup: { showInternet = true }, onConnect: { model.selectedPage = .guarding })
        case .activity:
            WitnessActivityPage()
        }
    }
}

struct WitnessOwnerDetails: View {
    @EnvironmentObject private var model: WitnessAppModel
    let nodeID: String
    let reportedName: String?
    let clusterID: String
    let onSave: () -> Void
    @State private var name: String
    @State private var error: String?
    @State private var copied = false

    init(nodeID: String, reportedName: String?, savedName: String?, clusterID: String, onSave: @escaping () -> Void) {
        self.nodeID = nodeID
        self.reportedName = reportedName
        self.clusterID = clusterID
        self.onSave = onSave
        _name = State(initialValue: savedName ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Server Details", systemImage: "desktopcomputer").font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                Text("Display name").font(.callout.weight(.medium))
                TextField("Display name", text: $name, prompt: Text(reportedName ?? "e.g. Primary Mac"))
                    .textFieldStyle(.roundedBorder)
                Text("Shown in Overview and Activity. Leave blank to use the server’s own name.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Node ID").font(.caption).foregroundStyle(.secondary)
                Text(nodeID).font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(12).consoleRowGroup()
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button(copied ? "Copied" : "Copy Node ID", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(nodeID, forType: .string)
                    copied = true
                }.buttonStyle(.bordered)
                Spacer()
                Button("Save Name", action: save).buttonStyle(.borderedProminent)
                    .disabled(!name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && WitnessNodeName.normalized(name) == nil)
            }
        }.padding(22).frame(width: 380)
    }

    private func save() {
        do {
            try model.saveNodeDisplayName(name, for: nodeID, clusterID: clusterID)
            onSave()
        } catch { self.error = error.localizedDescription }
    }
}

struct WitnessServiceCard: View {
    let title: String
    let symbol: String
    var brandAsset: String?
    let status: String
    let detail: String
    let health: WitnessHealth
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    ConsoleIconTile(symbol: symbol, brandAsset: brandAsset, active: health != .inactive)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.headline).lineLimit(1).minimumScaleFactor(0.85)
                    Label {
                        Text(status).foregroundStyle(health == .error || health == .warning ? health.tint : Color.primary)
                    } icon: {
                        Circle().fill(health.tint).frame(width: 7, height: 7)
                    }.font(.body.weight(.medium))
                    Text(detail).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true).help(detail)
                }
            }.padding(18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(.background.opacity(hovering ? 0.75 : 0.55), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.primary.opacity(hovering ? 0.10 : 0.06), lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(.plain).onHover { hovering = $0 }
            .accessibilityElement(children: .combine).accessibilityHint("Shows \(title)")
    }
}

private struct WitnessInternetPage: View {
    @EnvironmentObject private var model: WitnessAppModel
    let onSetup: () -> Void
    let onConnect: () -> Void
    @State private var error: String?
    @State private var confirmingPause = false
    @State private var showingConnectionSettings = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ConsolePageHeader(title: "Internet Access", subtitle: "A dedicated HTTPS address for this Ruru.") {
                    Button(model.configuration.tunnel.isConfigured ? "Manage Cloudflare" : "Set Up Cloudflare", action: onSetup)
                        .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                        .disabled(model.busy || model.internetBusy)
                }
                ConsoleSection(title: "Cloudflare Tunnel", accessory: {
                    WitnessStatusBadge(text: model.internetStateText, health: model.internetHealth)
                }, content: {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(spacing: 0) {
                            ConsoleSettingRow(title: "Cloudflare", subtitle: model.internetStatus.detail.isEmpty ? "The tunnel runs on this Mac independently of the guarded apps." : model.internetStatus.detail) {
                                ConsoleIconTile(symbol: "globe", brandAsset: "CloudflareLogo", active: model.internetHealth != .inactive)
                            }
                            Divider().padding(.leading, 16)
                            ConsoleSettingRow(title: "Website", subtitle: "The HTTPS endpoint used by all guarded services.") {
                                VStack(alignment: .trailing, spacing: 6) {
                                    Text(model.configuration.publicEndpoint.isEmpty ? "Not configured" : model.configuration.publicEndpoint)
                                        .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                                    if !model.configuration.publicEndpoint.isEmpty {
                                        Button("Copy Address", systemImage: "doc.on.doc") { model.copy(model.configuration.publicEndpoint) }
                                            .buttonStyle(.borderless)
                                    }
                                }
                            }
                            if model.configuration.tunnel.isConfigured {
                                Divider().padding(.leading, 16)
                                ConsoleSettingRow(title: "Public access", subtitle: model.configuration.tunnel.enabled ? "Reconnects automatically when this app starts its service." : "The tunnel is paused; its address and credentials are retained.") {
                                    Button(model.configuration.tunnel.enabled ? "Pause…" : "Resume") {
                                        if model.configuration.tunnel.enabled { confirmingPause = true }
                                        else { Task { await resume() } }
                                    }.buttonStyle(.bordered).disabled(model.busy || model.internetBusy)
                                }
                            }
                        }.consoleRowGroup()
                        if let problem = error ?? model.internetError {
                            ConsoleIssue(title: "Internet access needs attention", detail: problem)
                        } else if model.internetStatus.state == .error {
                            ConsoleIssue(title: "Tunnel unavailable", detail: model.internetStatus.detail, health: .error)
                        }
                        if model.internetBusy {
                            HStack { ProgressView().controlSize(.small); Text(model.internetProgress).font(.callout) }
                        }
                    }
                })
                ConsoleSection("Connection") {
                    VStack(spacing: 0) {
                        ConsoleSettingRow(title: "Local listener", subtitle: model.localURL) {
                            Button("Connection Settings…") { showingConnectionSettings = true }
                                .buttonStyle(.bordered).disabled(model.busy || model.internetBusy)
                        }
                        Divider().padding(.leading, 16)
                        ConsoleValueRow(title: "Public transport", value: model.configuration.publicEndpoint.isEmpty ? "Not configured" : "HTTPS")
                        Divider().padding(.leading, 16)
                        ConsoleSettingRow(title: "Service connections", subtitle: "Each service uses its own cluster ID and bearer token.") {
                            Button("Connection Details", action: onConnect).buttonStyle(.bordered)
                        }
                    }.consoleRowGroup()
                    Text("Cloudflare supplies public HTTPS. The local listener uses HTTP on this Mac.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 36).padding(.top, 32).padding(.bottom, 40)
                .frame(maxWidth: 1120, alignment: .leading).frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $showingConnectionSettings) {
            WitnessConnectionSettingsSheet(configuration: model.configuration).environmentObject(model)
        }
        .confirmationDialog("Pause public access?", isPresented: $confirmingPause) {
            Button("Pause Tunnel", role: .destructive) {
                Task {
                    do { try await model.pauseInternetAccess(); error = nil }
                    catch { self.error = error.localizedDescription }
                }
            }
        } message: { Text("Apps using this HTTPS address lose access to Ruru until the tunnel resumes.") }
    }

    private func resume() async {
        do { try await model.resumeInternetAccess(); error = nil }
        catch { self.error = error.localizedDescription }
    }
}

private struct WitnessActivityPage: View {
    @EnvironmentObject private var model: WitnessAppModel
    @State private var search = ""
    private var events: [WitnessEvent] {
        (model.snapshot?.events ?? []).filter {
            search.isEmpty || "\(model.serviceName(for: $0.clusterID)) \($0.clusterID) \($0.action) \($0.nodeID) \(model.nodeDisplayName(for: $0.nodeID, reportedName: $0.nodeName, clusterID: $0.clusterID)) \($0.term)".localizedCaseInsensitiveContains(search)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            ConsolePageHeader(title: "Activity", subtitle: "Ownership transfers and releases.")
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter by service, server, action, or term", text: $search).textFieldStyle(.plain)
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Clear filter")
                }
            }.padding(12).consoleRowGroup()
            ConsoleSection(title: "Ownership History", accessory: { Text("\(events.count) events") }, content: {
                if events.isEmpty {
                    ConsoleEmptyState(symbol: search.isEmpty ? "clock.arrow.circlepath" : "magnifyingglass",
                        title: search.isEmpty ? "No ownership changes yet" : "No matching events",
                        detail: search.isEmpty ? "Ruru records transfers when your servers acquire or release ownership." : "Try another node ID, action, or term.")
                        .frame(maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(events) { event in
                                WitnessEventRow(event: event)
                                if event.id != events.last?.id { Divider().padding(.leading, 42) }
                            }
                        }
                    }
                }
            }).frame(maxHeight: .infinity)
            Text("The last 256 ownership changes are retained. Routine renewals stay out of this history.")
                .font(.callout).foregroundStyle(.secondary)
        }.padding(.horizontal, 36).padding(.top, 32).padding(.bottom, 40)
            .frame(maxWidth: 1120, alignment: .leading).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct WitnessEventRow: View {
    @EnvironmentObject private var model: WitnessAppModel
    let event: WitnessEvent
    var compact = false
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: event.action == "Acquired" ? "checkmark.shield" : "arrow.right.circle")
                .foregroundStyle(event.action == "Acquired" ? Color.accentColor : Color.secondary)
                .font(.system(size: 16, weight: .medium)).frame(width: 22).padding(.top, 3)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(event.action == "Acquired" ? "Ownership acquired" : "Ownership released").font(.callout.weight(.medium))
                    Spacer(minLength: 8)
                    Text("Term \(event.term)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                Text(model.serviceName(for: event.clusterID) + " · " + model.nodeDisplayName(for: event.nodeID, reportedName: event.nodeName, clusterID: event.clusterID))
                    .font(.callout).foregroundStyle(.secondary)
                    .lineLimit(compact ? 1 : nil).help("Node ID: \(event.nodeID)").textSelection(.enabled)
                    .contextMenu {
                        Button("Copy Node ID", systemImage: "doc.on.doc") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(event.nodeID, forType: .string)
                        }
                    }
                Text(event.time.formatted(date: .abbreviated, time: .standard)).font(.caption).foregroundStyle(.tertiary)
            }
        }.padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor
extension WitnessAppModel {
    var serviceHealth: WitnessHealth {
        if isRecovering { return .warning }
        switch state {
        case .running: return .healthy
        case .failed: return .error
        case .stopped, .starting: return .inactive
        }
    }
    var internetStateText: String {
        if internetBusy { return "Setting up" }
        if !configuration.tunnel.isConfigured { return configuration.publicEndpoint.isEmpty ? "Not configured" : "External route" }
        if !configuration.tunnel.enabled { return "Paused" }
        if state != .running { return "Service stopped" }
        switch internetStatus.state {
        case .disabled: return "Stopped"
        case .enabling: return "Connecting"
        case .enabled: return "Connected"
        case .error: return "Unavailable"
        }
    }
    var internetHealth: WitnessHealth {
        guard state == .running, configuration.tunnel.enabled else { return .inactive }
        switch internetStatus.state {
        case .enabled: return .healthy
        case .error: return .error
        case .disabled, .enabling: return .inactive
        }
    }

    var coordinationStatusText: String {
        let enabledCount = configuration.guardedServices.filter { configuration.coordinationPolicy(for: $0.id).enabled }.count
        guard enabledCount > 0 else { return "Not enabled" }
        let freshCount = coordinationLocations.filter(\.fresh).count
        let total = coordinationLocations.count
        if total == 0 { return "Idle" }
        return "Reporting · \(freshCount == total ? "\(total)" : "\(freshCount)/\(total) fresh") \(total == 1 ? "location" : "locations")"
    }
    var coordinationHealth: WitnessHealth {
        let enabledCount = configuration.guardedServices.filter { configuration.coordinationPolicy(for: $0.id).enabled }.count
        guard enabledCount > 0 else { return .inactive }
        let total = coordinationLocations.count
        if total == 0 { return .inactive }
        let freshCount = coordinationLocations.filter(\.fresh).count
        return freshCount == total ? .healthy : .warning
    }

    var alertsStatusText: String {
        if let alertDeliveryError { return "Delivery failed" }
        var destinations: [String] = []
        if configuration.alerts.notifications { destinations.append("macOS") }
        if configuration.alerts.discord, discordConfigured { destinations.append("Discord") }
        return destinations.isEmpty ? "Not configured" : destinations.joined(separator: " + ")
    }
    var alertsHealth: WitnessHealth {
        if alertDeliveryError != nil { return .error }
        if !configuration.alerts.notifications && !(configuration.alerts.discord && discordConfigured) { return .inactive }
        return .healthy
    }
}

private let witnessHostName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
