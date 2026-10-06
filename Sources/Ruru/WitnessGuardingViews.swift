import SwiftUI
import WitnessKit

struct WitnessGuardingPage: View {
    @EnvironmentObject private var model: WitnessAppModel
    @State private var selectedID: String?
    @State private var adding = false

    private var selected: GuardedService? { model.configuration.guardedServices.first { $0.id == selectedID } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if let selected {
                    WitnessGuardedServiceDetails(service: selected) { selectedID = nil }
                } else {
                    ConsolePageHeader(title: "Guarding", subtitle: "The services Ruru guards and the servers participating in them.") {
                        Button("Add Service", systemImage: "plus") { adding = true }
                            .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                            .disabled(model.busy || model.internetBusy || model.configuration.guardedServices.count >= 32)
                    }
                    if model.legacyStorageNeedsReplacement { WitnessLegacyStorageNotice() }
                    WitnessGuardedServicesSummary { selectedID = $0.id }
                    Label("Each service has its own ownership group and connection details.", systemImage: "checkmark.shield")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 36).padding(.top, 32).padding(.bottom, 40)
                .frame(maxWidth: 1120, alignment: .leading).frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $adding) { WitnessAddServiceSheet().environmentObject(model) }
    }
}

struct WitnessGuardedServicesSummary: View {
    @EnvironmentObject private var model: WitnessAppModel
    let onOpen: (GuardedService) -> Void
    var body: some View {
        ConsoleSection(title: "Guarded Services", accessory: {
            Text(model.guardingSummary)
        }, content: {
            VStack(spacing: 0) {
                if model.configuration.guardedServices.isEmpty {
                    ConsoleEmptyState(symbol: "checkmark.shield", title: "No guarded services",
                                      detail: "Use Add Service in Guarding to connect an app. Removed services cannot acquire or renew ownership.")
                }
                ForEach(model.configuration.guardedServices) { service in
                    Button { onOpen(service) } label: {
                        HStack(spacing: 14) {
                            ConsoleIconTile(symbol: service.symbol, active: model.guardHealth(for: service.clusterID) == .healthy)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(service.name).font(.headline)
                                Text(service.kind.rawValue + " · " + model.guardOwner(for: service.clusterID))
                                    .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer(minLength: 8)
                            WitnessStatusBadge(text: model.guardStatus(for: service.clusterID), health: model.guardHealth(for: service.clusterID))
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }.padding(16).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityHint("Shows service ownership and known servers")
                    if service.id != model.configuration.guardedServices.last?.id { Divider().padding(.leading, 64) }
                }
            }.consoleRowGroup()
        })
    }
}

private struct WitnessGuardedServiceDetails: View {
    @EnvironmentObject private var model: WitnessAppModel
    let service: GuardedService
    let onBack: () -> Void
    @State private var connecting = false
    @State private var renaming = false
    @State private var selectedNode: String?
    @State private var confirmingRemoval = false
    @State private var removalError: String?
    @State private var choosingPrimary = false
    @State private var preferenceError: String?
    private var preference: WitnessPrimaryPreference { model.configuration.primaryPreference(for: service.id) }
    private var lease: LeaseStatus? { model.lease(for: service.clusterID) }
    private var nodes: [String] { model.knownNodes(for: service.clusterID) }
    private var events: [WitnessEvent] { model.events(for: service.clusterID) }

    var body: some View {
        Button("Guarding", systemImage: "chevron.left", action: onBack).buttonStyle(.borderless)
        ConsolePageHeader(title: service.name, subtitle: service.kind.rawValue + " · " + service.clusterID) {
            HStack(spacing: 10) {
                Button("Remove…", systemImage: "trash", role: .destructive) { confirmingRemoval = true }
                    .buttonStyle(.bordered).buttonBorderShape(.capsule)
                    .disabled(model.busy || model.internetBusy)
                Button("Rename", systemImage: "pencil") { renaming = true }.buttonStyle(.bordered).buttonBorderShape(.capsule)
                Button("Connection Details", systemImage: "link") { connecting = true }
                    .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
            }
        }
        if let removalError { ConsoleIssue(title: "Service could not be removed", detail: removalError) }
        ConsoleSection(title: "Ownership", accessory: {
            WitnessStatusBadge(text: model.guardStatus(for: service.clusterID), health: model.guardHealth(for: service.clusterID))
        }, content: {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    ConsoleIconTile(symbol: "desktopcomputer", active: (lease?.remainingSeconds ?? 0) > 0, size: 46)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Current owner").font(.callout).foregroundStyle(.secondary)
                        Text(model.guardOwner(for: service.clusterID)).font(.title2.weight(.semibold)).textSelection(.enabled)
                    }
                }
                HStack(spacing: 32) {
                    value("Ownership term", String(lease?.term ?? 0))
                    value("Lease remaining", "\(Int(ceil(lease?.remainingSeconds ?? 0))) seconds")
                }
                if (lease?.remainingSeconds ?? 0) > 0 {
                    ProgressView(value: min(30, lease?.remainingSeconds ?? 0), total: 30)
                } else {
                    Text("Connect this service’s servers using its connection details. Any number of participants can compete; one holds ownership at a time.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        })
        ConsoleSection("Preferred Primary") {
            HStack(spacing: 14) {
                ConsoleIconTile(symbol: "star", active: preference.preferredPrimaryNodeID != nil, size: 46)
                VStack(alignment: .leading, spacing: 5) {
                    if let node = preference.preferredPrimaryNodeID {
                        Text(model.nodeDisplayName(for: node, reportedName: model.reportedName(for: node, clusterID: service.clusterID), clusterID: service.clusterID))
                            .font(.headline).textSelection(.enabled).id(node + "-name")
                        Text(node).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled).id(node + "-id")
                    } else {
                        Text("No preference").font(.headline)
                        Text("Clients use their normal ownership selection.").font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 12)
                Button(preference.preferredPrimaryNodeID == nil ? "Choose Primary…" : "Change…") { choosingPrimary = true }
                    .buttonStyle(.bordered).disabled(model.busy || model.internetBusy)
            }
            if preference.preferredPrimaryNodeID != nil {
                Button("Clear Preference") {
                    Task {
                        do { try await model.setPreferredPrimary(nil, for: service.id); preferenceError = nil }
                        catch { preferenceError = error.localizedDescription }
                    }
                }.buttonStyle(.borderless).disabled(model.busy || model.internetBusy)
            }
            if let preferenceError { ConsoleIssue(title: "Preference could not be saved", detail: preferenceError) }
            Text("Compatible clients use this preference for a coordinated handover. Saving it does not transfer ownership or confirm that a server is online. Failover remains available when the preferred Primary is unavailable.")
                .font(.callout).foregroundStyle(.secondary)
        }
        ConsoleSection(title: "Known Servers", accessory: { Text("\(nodes.count) observed") }, content: {
            if nodes.isEmpty {
                ConsoleEmptyState(symbol: "server.rack", title: "No servers observed yet", detail: "Servers appear after successfully participating in this service’s ownership.")
            } else {
                VStack(spacing: 0) {
                    ForEach(nodes, id: \.self) { node in
                        Button { selectedNode = node } label: {
                            HStack(spacing: 14) {
                                ConsoleIconTile(symbol: "desktopcomputer", size: 34)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(model.nodeDisplayName(for: node, reportedName: model.reportedName(for: node, clusterID: service.clusterID), clusterID: service.clusterID))
                                        .font(.callout.weight(.semibold))
                                    Text(node).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 5) {
                                    if preference.preferredPrimaryNodeID == node {
                                        Label("Preferred Primary", systemImage: "star.fill").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Text(lease?.ownerNodeID == node && (lease?.remainingSeconds ?? 0) > 0 ? "Current owner" : "Previously observed")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Image(systemName: "info.circle").foregroundStyle(.secondary)
                            }.padding(12).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        if node != nodes.last { Divider().padding(.leading, 58) }
                    }
                }.consoleRowGroup()
            }
            Text("Known servers come from retained ownership history. This list does not indicate standby health or uptime.")
                .font(.caption).foregroundStyle(.secondary)
        })
        ConsoleSection("Recent Activity") {
            if events.isEmpty {
                ConsoleEmptyState(symbol: "clock", title: "No ownership changes yet", detail: "Acquisitions and releases for this service appear here.")
            } else {
                VStack(spacing: 0) {
                    ForEach(events.prefix(10)) { event in
                        WitnessEventRow(event: event)
                        if event.id != events.prefix(10).last?.id { Divider().padding(.leading, 42) }
                    }
                }
            }
        }
        .sheet(isPresented: $connecting) { ConnectionDetailsSheet(clusterID: service.clusterID).environmentObject(model) }
        .sheet(isPresented: $choosingPrimary) { WitnessPreferredPrimarySheet(service: service).environmentObject(model) }
        .sheet(isPresented: $renaming) { WitnessRenameServiceSheet(service: service).environmentObject(model) }
        .confirmationDialog("Remove \(service.name)?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button("Remove Service", role: .destructive) {
                Task {
                    do { try await model.removeGuardedService(id: service.id); onBack() }
                    catch { removalError = error.localizedDescription }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Its servers will no longer be able to acquire or renew ownership. Existing permission expires within 30 seconds. Ownership terms and history are retained, and other services keep running.")
        }
        .popover(isPresented: Binding(get: { selectedNode != nil }, set: { if !$0 { selectedNode = nil } })) {
            if let node = selectedNode {
                WitnessOwnerDetails(nodeID: node, reportedName: model.reportedName(for: node, clusterID: service.clusterID),
                                    savedName: service.nodeDisplayNames[node], clusterID: service.clusterID) {
                    selectedNode = nil
                }.environmentObject(model).id(node)
            }
        }
    }
    private func value(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
        }
    }
}

private struct WitnessAddServiceSheet: View {
    @EnvironmentObject private var model: WitnessAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var clusterID = ""
    @State private var kind = GuardedService.Kind.custom
    @State private var saving = false
    @State private var error: String?
    private var valid: Bool {
        let service = GuardedService(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                    clusterID: clusterID.trimmingCharacters(in: .whitespacesAndNewlines), kind: kind)
        return service.isValid && !model.configuration.guardedServices.contains { $0.clusterID == service.clusterID }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            WitnessSheetHeader(title: "Add Service", subtitle: "Give another app its own ownership group.", symbol: "checkmark.shield")
            VStack(alignment: .leading, spacing: 16) {
                TextField("Service name", text: $name, prompt: Text("e.g. SwiftBot Production or Backup Worker"))
                Picker("Application", selection: $kind) { ForEach(GuardedService.Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                TextField("Cluster ID", text: $clusterID, prompt: Text("A unique ID used by this service’s servers"))
                Text("Use the same cluster ID on every participant in this service. Connection details will include a separate bearer token.")
                    .font(.callout).foregroundStyle(.secondary)
                if let error { ConsoleIssue(title: "Service could not be added", detail: error) }
            }.textFieldStyle(.roundedBorder)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Spacer()
                Button(saving ? "Adding…" : "Add Service") {
                    saving = true
                    Task {
                        do { try await model.addGuardedService(name: name, clusterID: clusterID, kind: kind); dismiss() }
                        catch { self.error = error.localizedDescription; saving = false }
                    }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!valid || saving || model.busy)
            }
        }.padding(24).frame(width: 560).interactiveDismissDisabled(saving)
    }
}

private struct WitnessRenameServiceSheet: View {
    @EnvironmentObject private var model: WitnessAppModel
    @Environment(\.dismiss) private var dismiss
    let service: GuardedService
    @State private var name: String
    @State private var error: String?
    init(service: GuardedService) { self.service = service; _name = State(initialValue: service.name) }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Rename Service").font(.title2.weight(.semibold))
            TextField("Service name", text: $name).textFieldStyle(.roundedBorder)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    do { try model.renameService(id: service.id, name: name); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(WitnessNodeName.normalized(name) == nil || name.utf8.count > 128)
            }
        }.padding(24).frame(width: 420)
    }
}

@MainActor
extension WitnessAppModel {
    func guardOwner(for clusterID: String) -> String {
        guard let lease = lease(for: clusterID), lease.remainingSeconds > 0 else { return "No active owner" }
        return nodeDisplayName(for: lease.ownerNodeID, reportedName: lease.ownerNodeName, clusterID: clusterID)
    }
    func guardStatus(for clusterID: String) -> String {
        if state != .running { return state.rawValue }
        if isRecovering { return "Recovering" }
        return (lease(for: clusterID)?.remainingSeconds ?? 0) > 0 ? "Guarding" : "Waiting for owner"
    }
    func guardHealth(for clusterID: String) -> WitnessHealth {
        if state != .running || isRecovering { return serviceHealth }
        return (lease(for: clusterID)?.remainingSeconds ?? 0) > 0 ? .healthy : .inactive
    }
}
