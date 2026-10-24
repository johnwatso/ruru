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
        .onAppear {
            guard let id = model.pendingGuardedServiceID else { return }
            model.pendingGuardedServiceID = nil
            if model.configuration.guardedServices.contains(where: { $0.id == id }) { selectedID = id }
        }
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
                            WitnessGuardedServiceIcon(service: service, active: model.guardHealth(for: service.clusterID) == .healthy)
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

struct WitnessGuardedServiceIcon: View {
    @EnvironmentObject private var model: WitnessAppModel
    let service: GuardedService
    var active = true
    var size: CGFloat = 42

    var body: some View {
        if let custom = model.serviceIcons[service.id] {
            Image(nsImage: custom).resizable().interpolation(.high).scaledToFit()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
                .saturation(active ? 1 : 0).opacity(active ? 1 : 0.55)
                .accessibilityHidden(true)
        } else if let asset = service.brandAsset {
            Image(asset).resizable().interpolation(.high).scaledToFit()
                .frame(width: size, height: size).accessibilityHidden(true)
        } else {
            ConsoleIconTile(symbol: service.symbol, active: active, size: size)
        }
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
    private var grouped: (current: [String], earlier: [String]) { model.groupedKnownNodes(for: service.clusterID) }
    private var nodes: [String] { grouped.current }
    @State private var showingEarlier = false
    private var events: [WitnessEvent] { model.events(for: service.clusterID) }

    private func presenceLabel(_ role: ParticipantRole) -> String {
        switch role {
        case .standby: "Standby · Recent contact"
        case .active: "Active · Recent contact"
        case .worker: "Worker · Recent contact"
        case .unknown: "Recent contact"
        }
    }

    private static func powerLabel(_ observation: ParticipantObservation) -> (text: String, symbol: String, color: Color)? {
        guard let source = observation.powerSource, source != .unknown else { return nil }
        let onBattery = observation.externalPower == false
        let percent = observation.batteryPercent
        if source == .ups && onBattery {
            let detail = percent.map { " · \($0)%" } ?? ""
            return ("UPS on battery\(detail)", "bolt.trianglebadge.exclamationmark", .orange)
        }
        if source == .ups {
            let detail = percent.map { " · \($0)%" } ?? ""
            return ("UPS\(detail)", "bolt.shield", .green)
        }
        if source == .battery && onBattery {
            let detail = percent.map { " · \($0)%" } ?? ""
            return ("On battery\(detail)", "battery.25percent", percent.map({ $0 <= 20 }) == true ? .red : .orange)
        }
        if source == .battery {
            let detail = percent.map { " · \($0)%" } ?? ""
            return ("Charging\(detail)", "battery.100percent.bolt", .green)
        }
        return ("AC power", "powerplug", .green)
    }

    private func serverAccessibilityLabel(_ node: String) -> String {
        var parts = [model.nodeDisplayName(for: node,
            reportedName: model.reportedName(for: node, clusterID: service.clusterID), clusterID: service.clusterID)]
        if lease?.ownerNodeID == node && (lease?.remainingSeconds ?? 0) > 0 { parts.append("Current owner") }
        if let observation = model.participant(for: node, clusterID: service.clusterID) {
            parts.append(observation.fresh ? presenceLabel(observation.role) : "Contact stale")
            if observation.fresh, observation.sessionEnding == true { parts.append("System logout or shutdown requested") }
            if observation.fresh, let power = Self.powerLabel(observation) { parts.append(power.text) }
            parts.append("Last seen \(Int(observation.ageSeconds)) seconds ago")
        } else { parts.append("Presence unknown") }
        if preference.preferredPrimaryNodeID == node { parts.append("Preferred Primary") }
        return parts.joined(separator: ", ")
    }

    /// A quiet, optional setting: most services never need one.
    private var preferredPrimaryRow: some View {
        HStack(spacing: 8) {
            Image(systemName: preference.preferredPrimaryNodeID == nil ? "star" : "star.fill")
                .foregroundStyle(.secondary).accessibilityHidden(true)
            Text("Preferred Primary").foregroundStyle(.secondary)
            Text(preference.preferredPrimaryNodeID.map {
                model.nodeDisplayName(for: $0, reportedName: model.reportedName(for: $0, clusterID: service.clusterID),
                                      clusterID: service.clusterID)
            } ?? "None")
            Spacer(minLength: 8)
            Menu("Change") {
                Button("Choose…") { choosingPrimary = true }
                if preference.preferredPrimaryNodeID != nil {
                    Button("Clear Preference") {
                        Task {
                            do { try await model.setPreferredPrimary(nil, for: service.id); preferenceError = nil }
                            catch { preferenceError = error.localizedDescription }
                        }
                    }
                }
            }
            .menuStyle(.borderlessButton).fixedSize()
            .disabled(model.busy || model.internetBusy)
        }
        .font(.callout)
        .padding(.horizontal, 4)
        .help("Compatible clients use this for a coordinated handover. It never transfers ownership, confirms a server is online, or blocks failover.")
    }

    var body: some View {
        Button("Guarding", systemImage: "chevron.left", action: onBack).buttonStyle(.borderless)
        HStack(spacing: 16) {
            WitnessGuardedServiceIcon(service: service, size: 48)
            ConsolePageHeader(title: service.name, subtitle: service.kind.rawValue + " · " + service.clusterID) {
                HStack(spacing: 10) {
                    Button("Remove…", systemImage: "trash", role: .destructive) { confirmingRemoval = true }
                        .buttonStyle(.bordered).buttonBorderShape(.capsule)
                        .disabled(model.busy || model.internetBusy)
                    Button("Edit", systemImage: "pencil") { renaming = true }.buttonStyle(.bordered).buttonBorderShape(.capsule)
                    Button("Connection Details", systemImage: "link") { connecting = true }
                        .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                }
            }
        }
        if let removalError { ConsoleIssue(title: "Service could not be removed", detail: removalError) }
        ConsoleSettingRow(title: "Resource sharing", subtitle: model.configuration.coordinationPolicy(for: service.id).enabled
                          ? "Resource catalogue enabled for this service." : "Optional. Guarding works without resource sharing.") {
            Button("Open Coordination") {
                model.pendingCoordinationServiceID = service.id
                model.selectedPage = .coordination
            }
        }.consoleRowGroup()
        if !model.pairingRequests(for: service.clusterID).isEmpty {
            ConsoleSection(title: "Pairing Requests", accessory: { Text("Expire after 10 minutes") }, content: {
                WitnessPairingRequestList(service: service)
            })
        }
        if !(model.pairedNodes[service.clusterID] ?? []).isEmpty {
            ConsoleSection(title: "Paired Servers", accessory: { Text("Each has its own token") }, content: {
                WitnessPairedServerList(service: service)
            })
        }
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
                WitnessLeaseCode(lease: lease, leaseSeconds: Double(service.leaseSeconds), recovering: model.isRecovering)
                if (lease?.remainingSeconds ?? 0) > 0 {
                    Label("Ruru's recorded grant expiry. The client's own local deadline is authoritative and may differ.",
                          systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("The term is the fencing token servers attach to their work; it only ever increases. The ring shows how long the current grant lasts without another renewal, and refills each time the owner renews.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Connect this service’s servers using its connection details. Any number of participants can compete; one holds ownership at a time.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        })
        ConsoleSection(title: "Known Servers", accessory: { Text("\(nodes.count) \(nodes.count == 1 ? "server" : "servers")") }, content: {
            if nodes.isEmpty {
                ConsoleEmptyState(symbol: "server.rack", title: "No servers observed yet", detail: "Compatible servers report their presence while active or in standby. Earlier clients appear after holding ownership.")
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
                                    if lease?.ownerNodeID == node && (lease?.remainingSeconds ?? 0) > 0 {
                                        Text("Current owner").font(.caption).foregroundStyle(.secondary)
                                    }
                                    if let observation = model.participant(for: node, clusterID: service.clusterID) {
                                        Label(observation.fresh ? presenceLabel(observation.role) : "Contact stale",
                                              systemImage: observation.fresh ? "checkmark.circle" : "clock")
                                            .font(.caption).foregroundStyle(observation.fresh ? Color.green : Color.secondary)
                                        if observation.fresh, observation.sessionEnding == true {
                                            Label("Logout or shutdown requested", systemImage: "power")
                                                .font(.caption).foregroundStyle(.orange)
                                        }
                                        if observation.fresh, let powerLabel = Self.powerLabel(observation) {
                                            Label(powerLabel.text, systemImage: powerLabel.symbol)
                                                .font(.caption).foregroundStyle(powerLabel.color)
                                        }
                                        Text("Last seen \(Int(observation.ageSeconds))s ago").font(.caption).foregroundStyle(.secondary)
                                    } else {
                                        Text("Presence unknown").font(.caption).foregroundStyle(.secondary)
                                    }
                                    if let status = model.operationalStatus(for: node, clusterID: service.clusterID) {
                                        Label(status.fresh ? Self.operationalLabel(status.state) : "Operational status stale",
                                              systemImage: status.fresh ? Self.operationalSymbol(status.state) : "clock")
                                            .font(.caption).foregroundStyle(status.fresh && status.state == .ready ? Color.green : Color.secondary)
                                    }
                                }
                                Image(systemName: "info.circle").foregroundStyle(.secondary)
                            }.padding(12).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .accessibilityLabel(serverAccessibilityLabel(node))
                            .accessibilityHint("Shows server details")
                        if node != nodes.last { Divider().padding(.leading, 58) }
                    }
                }.consoleRowGroup()
            }
            if !grouped.earlier.isEmpty {
                DisclosureGroup(isExpanded: $showingEarlier) {
                    VStack(spacing: 0) {
                        ForEach(grouped.earlier, id: \.self) { node in
                            Button { selectedNode = node } label: {
                                HStack {
                                    Text(model.nodeDisplayName(for: node, reportedName: model.reportedName(for: node, clusterID: service.clusterID), clusterID: service.clusterID))
                                        .font(.callout)
                                    Text(node).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                                    Spacer()
                                }.padding(.vertical, 6).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                        HStack {
                            Button("Forget Earlier Identities") {
                                Task {
                                    do { try await model.forgetEarlierIdentities(for: service.clusterID); preferenceError = nil }
                                    catch { preferenceError = error.localizedDescription }
                                }
                            }.disabled(model.busy || model.internetBusy)
                            Spacer()
                        }.padding(.top, 6)
                        Text("These IDs appear only in ownership history. A server with the same name is reporting under a newer ID, usually after a reinstall or reset. Forgetting only hides them here; ownership history and terms are kept.")
                            .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                    }.padding(.top, 6)
                } label: {
                    Text("Earlier identities (\(grouped.earlier.count))").font(.callout).foregroundStyle(.secondary)
                }
            }
            preferredPrimaryRow
            if let replacement = model.liveReplacementForPreferredPrimary(for: service.clusterID) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.orange).accessibilityHidden(true)
                    Text("The preferred primary is not reporting, but a server with the same name is under a newer ID.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button("Use Current") {
                        Task {
                            do { try await model.setPreferredPrimary(replacement, for: service.id); preferenceError = nil }
                            catch { preferenceError = error.localizedDescription }
                        }
                    }.disabled(model.busy || model.internetBusy)
                }.padding(.horizontal, 4)
            }
            if let preferenceError { ConsoleIssue(title: "Preference could not be saved", detail: preferenceError) }
            Text("Recent contact comes from authenticated server reports. Standby and active roles are reported by each server; current ownership comes from Ruru’s lease. Contact becomes stale after 45 seconds and does not prove failover readiness.")
                .font(.caption).foregroundStyle(.secondary)
        })
        ConsoleSection("Recent Activity") {
            let items = model.activityFeed(clusterID: service.clusterID, limit: 10)
            if items.isEmpty {
                ConsoleEmptyState(symbol: "clock", title: "No activity yet", detail: "Ownership changes and server reports for this service appear here.")
            } else {
                ActivityFeedList(items: items, showsService: false)
            }
        }
        .sheet(isPresented: $connecting) { ConnectionDetailsSheet(clusterID: service.clusterID).environmentObject(model) }
        .sheet(isPresented: $choosingPrimary) { WitnessPreferredPrimarySheet(service: service).environmentObject(model) }
        .sheet(isPresented: $renaming) { WitnessEditServiceSheet(service: service).environmentObject(model) }
        .confirmationDialog("Remove \(service.name)?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button("Remove Service", role: .destructive) {
                Task {
                    do { try await model.removeGuardedService(id: service.id); onBack() }
                    catch { removalError = error.localizedDescription }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Its servers will no longer be able to acquire or renew ownership. Existing permission lasts only until each client's current lease deadline. Ownership terms and history are retained, and other services keep running.")
        }
        .sheet(isPresented: Binding(get: { selectedNode != nil }, set: { if !$0 { selectedNode = nil } })) {
            if let node = selectedNode {
                WitnessOwnerDetails(nodeID: node, reportedName: model.reportedName(for: node, clusterID: service.clusterID),
                                    savedName: service.nodeDisplayNames[node], clusterID: service.clusterID) {
                    selectedNode = nil
                }.environmentObject(model).id(node)
            }
        }
    }

    private static func operationalLabel(_ state: OperationalState) -> String {
        switch state {
        case .ready: "Operationally ready"
        case .synchronizing: "Synchronising"
        case .outdated: "Needs sync"
        case .degraded: "Operationally degraded"
        case .unknown: "Operational status unknown"
        }
    }

    private static func operationalSymbol(_ state: OperationalState) -> String {
        switch state {
        case .ready: "checkmark.seal"
        case .synchronizing: "arrow.triangle.2.circlepath"
        case .outdated: "arrow.clockwise"
        case .degraded: "exclamationmark.triangle"
        case .unknown: "questionmark.circle"
        }
    }
}

struct WitnessAddServiceSheet: View {
    @EnvironmentObject private var model: WitnessAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var clusterID = ""
    let subtitle: String
    let symbol: String

    init(subtitle: String = "Give an app its own ownership group.", symbol: String = "checkmark.shield") {
        self.subtitle = subtitle
        self.symbol = symbol
    }

    @State private var kind = GuardedService.Kind.custom
    @State private var leaseSeconds = GuardedService.defaultLeaseSeconds
    @State private var saving = false
    @State private var error: String?
    @State private var iconPNG: Data?
    @State private var iconError: String?
    private var valid: Bool {
        let service = GuardedService(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                    clusterID: clusterID.trimmingCharacters(in: .whitespacesAndNewlines), kind: kind,
                                    leaseSeconds: leaseSeconds)
        return service.isValid && !model.configuration.guardedServices.contains { $0.clusterID == service.clusterID }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            WitnessSheetHeader(title: "Add Service", subtitle: subtitle, symbol: symbol)
            VStack(alignment: .leading, spacing: 16) {
                WitnessServiceIconPicker(image: iconPNG.flatMap { NSImage(data: $0) }, templateSymbol: GuardedService(name: "", clusterID: "", kind: kind).symbol,
                                         onPick: pickIcon, onClear: { iconPNG = nil }, onError: { iconError = $0 })
                if let iconError { ConsoleIssue(title: "Icon could not be used", detail: iconError) }
                TextField("Service name", text: $name, prompt: Text("e.g. Production Bot or Media Server"))
                Picker("Application", selection: $kind) { ForEach(GuardedService.Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                TextField("Cluster ID", text: $clusterID, prompt: Text("A unique ID used by this service’s servers"))
                WitnessLeaseLengthPicker(seconds: $leaseSeconds)
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
                        do { try await model.addGuardedService(name: name, clusterID: clusterID, kind: kind, leaseSeconds: leaseSeconds, iconPNG: iconPNG); dismiss() }
                        catch { self.error = error.localizedDescription; saving = false }
                    }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!valid || saving || model.busy)
            }
        }
        .onChange(of: kind) { _, selectedKind in
            leaseSeconds = GuardedService.defaultLeaseSeconds(for: selectedKind)
        }
        .padding(24).frame(width: 560).interactiveDismissDisabled(saving)
        .serviceIconDrop(onPick: pickIcon, onError: { iconError = $0 })
    }

    private func pickIcon(_ pick: RuruServiceIcons.Pick) {
        iconPNG = pick.png
        iconError = nil
        // Dropping an app fills in its name unless one has been typed already.
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let suggested = pick.suggestedName { name = suggested }
    }
}

/// Lease lengths offered in the UI; all lie within GuardedService.leaseSecondsRange.
struct WitnessLeaseLengthPicker: View {
    @Binding var seconds: Int
    private static let choices = [10, 15, 30, 60, 120, 300]
    var body: some View {
        Picker("Lease length", selection: $seconds) {
            ForEach(Self.choices.contains(seconds) ? Self.choices : (Self.choices + [seconds]).sorted(), id: \.self) { value in
                Text(value < 60 ? "\(value) seconds" : value == 60 ? "1 minute" : "\(value / 60) minutes").tag(value)
            }
        }
    }
}

private struct WitnessEditServiceSheet: View {
    @EnvironmentObject private var model: WitnessAppModel
    @Environment(\.dismiss) private var dismiss
    let service: GuardedService
    @State private var name: String
    @State private var leaseSeconds: Int
    @State private var saving = false
    @State private var error: String?
    /// nil until the icon is edited; then `.some(nil)` means "use the default".
    @State private var editedIcon: Data??
    @State private var iconError: String?
    init(service: GuardedService) {
        self.service = service
        _name = State(initialValue: service.name)
        _leaseSeconds = State(initialValue: service.leaseSeconds)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Edit Service").font(.title2.weight(.semibold))
            WitnessServiceIconPicker(image: displayedIcon, templateSymbol: service.symbol,
                                     onPick: { editedIcon = .some($0.png); iconError = nil },
                                     onClear: { editedIcon = .some(nil) }, onError: { iconError = $0 })
            if let iconError { ConsoleIssue(title: "Icon could not be used", detail: iconError) }
            TextField("Service name", text: $name).textFieldStyle(.roundedBorder)
            WitnessLeaseLengthPicker(seconds: $leaseSeconds)
            Text("Shorter leases fail over faster; longer leases need fewer renewals. A new length applies from the owner’s next renewal, and after a restart Ruru waits for the longest lease it granted.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Spacer()
                Button("Save") {
                    saving = true
                    Task {
                        do {
                            try await model.updateService(id: service.id, name: name, leaseSeconds: leaseSeconds)
                            if let editedIcon { model.setServiceIcon(editedIcon, for: service.id) }
                            dismiss()
                        }
                        catch { self.error = error.localizedDescription; saving = false }
                    }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(WitnessNodeName.normalized(name) == nil || name.utf8.count > 128 || saving || model.busy)
            }
        }.padding(24).frame(width: 460).interactiveDismissDisabled(saving)
            .serviceIconDrop(onPick: { editedIcon = .some($0.png); iconError = nil }, onError: { iconError = $0 })
    }

    private var displayedIcon: NSImage? {
        guard let editedIcon else { return model.serviceIcons[service.id] }
        return editedIcon.flatMap { NSImage(data: $0) }
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
    /// Concise Overview status. Lease ownership, participant contact and
    /// application-reported readiness are kept distinct: a held lease alone is
    /// reported as "Owned", never as healthy.
    func overviewStatus(for clusterID: String) -> (text: String, health: WitnessHealth) {
        if state != .running { return (state == .stopped ? "Authority stopped" : state.rawValue, serviceHealth) }
        if isRecovering { return ("Recovering", .warning) }
        guard (lease(for: clusterID)?.remainingSeconds ?? 0) > 0, let owner = lease(for: clusterID)?.ownerNodeID else {
            return ("Unowned", .inactive)
        }
        if let report = operationalStatus(for: owner, clusterID: clusterID), report.fresh {
            switch report.state {
            case .ready: return ("Ready", .healthy)
            case .synchronizing: return ("Synchronising", .warning)
            case .outdated: return ("Outdated", .warning)
            case .degraded: return ("Degraded", .warning)
            case .unknown: break
            }
        }
        if let contact = participant(for: owner, clusterID: clusterID), !contact.fresh {
            return ("Contact stale", .warning)
        }
        return ("Owned", .inactive)
    }
    func guardHealth(for clusterID: String) -> WitnessHealth {
        if state != .running || isRecovering { return serviceHealth }
        return (lease(for: clusterID)?.remainingSeconds ?? 0) > 0 ? .healthy : .inactive
    }
}

/// The lease shown like a one-time code: the ownership term in grouped digits
/// with a countdown ring for the current grant. Text updates once a second;
/// SwiftUI animates only the ring's stroke between ticks. After app inactivity,
/// a status symbol replaces the countdown without a view-owned timer.
struct WitnessLeaseCode: View {
    let lease: LeaseStatus?
    let leaseSeconds: Double
    var recovering = false
    @State private var anchor = (remaining: 0.0, at: Date.distantPast)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.ruruLeaseAnimationsEnabled) private var animationsEnabled

    private var owned: Bool { (lease?.remainingSeconds ?? 0) > 0 }
    private var idleState: WitnessLeasePresentation {
        .init(lease: lease, leaseSeconds: leaseSeconds, recovering: recovering)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Ownership term").font(.callout).foregroundStyle(.secondary)
                Text(Self.grouped(lease?.term ?? 0))
                    .font(.system(size: 30, weight: .semibold, design: .monospaced))
                    .foregroundStyle(owned ? .primary : .secondary)
                    .contentTransition(.numericText(value: Double(lease?.term ?? 0)))
                    .animation(reduceMotion || !animationsEnabled ? nil : .snappy, value: lease?.term)
                    .textSelection(.enabled)
                    .accessibilityLabel("Ownership term \(lease?.term ?? 0)")
            }
            Spacer(minLength: 12)
            if !animationsEnabled {
                idleStatus
                    .transition(.opacity)
            } else if owned, !recovering {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    countdown(max(0, anchor.remaining - context.date.timeIntervalSince(anchor.at)))
                }
            } else {
                countdown(0)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .consoleRowGroup()
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: animationsEnabled)
        // Keep the animated/selectable code a single stable accessibility node.
        // macOS can otherwise recurse while resolving its child labels.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Ownership term \(lease?.term ?? 0), \(animationsEnabled && owned && !recovering ? "\(Int(ceil(lease?.remainingSeconds ?? 0))) seconds left in this grant" : idleState.idleCaption)")
        .onAppear(perform: resetAnchor)
        .onChange(of: lease?.remainingSeconds) { resetAnchor() }
        .onChange(of: animationsEnabled) { resetAnchor() }
    }

    private func resetAnchor() { anchor = (lease?.remainingSeconds ?? 0, Date()) }

    private var idleStatus: some View {
        HStack(spacing: 10) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(idleState.idleCaption).font(.callout.weight(.medium)).foregroundStyle(idleTint)
                Text("\(Int(leaseSeconds)) s lease").font(.caption).foregroundStyle(.secondary)
            }
            ZStack {
                Image(systemName: idleSymbolName)
                    .font(.system(size: 36))
                    .foregroundStyle(idleTint)
                    .id(idleState)
                    .transition(.opacity)
            }
            .frame(width: 40, height: 40)
            .accessibilityHidden(true)
        }
        // Fade only on a status edge, never on each poll or renewal.
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: idleState)
        .help(idleState == .renewing ? "Lease renewals are current." : idleState.idleCaption)
    }

    private var idleTint: Color {
        switch idleState {
        case .renewing: .green
        case .late, .recovering: .orange
        case .critical: .red
        case .unowned: .secondary
        }
    }

    private var idleSymbolName: String {
        // Keep a native fallback on older system symbol catalogues.
        idleState == .renewing ? Self.idleRenewalSymbolName : idleState.symbolName
    }

    private static let idleRenewalSymbolName: String = {
        let requested = WitnessLeasePresentation.renewing.symbolName
        return NSImage(systemSymbolName: requested, accessibilityDescription: nil) != nil
            ? requested : "arrow.triangle.2.circlepath.circle.fill"
    }()

    private func countdown(_ remaining: Double) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(caption(remaining)).font(.callout.weight(.medium)).foregroundStyle(tint(remaining))
                Text("\(Int(leaseSeconds)) s lease").font(.caption).foregroundStyle(.secondary)
            }
            WitnessLeaseRing(fraction: owned && !recovering ? remaining / leaseSeconds : 0,
                             seconds: owned && !recovering ? remaining : nil, tint: tint(remaining),
                             animatesCountdown: owned && !recovering && !reduceMotion)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(owned && !recovering ? "\(Int(ceil(remaining))) seconds left in this grant" : caption(remaining))
    }

    private func caption(_ remaining: Double) -> String {
        if recovering { return "Recovering" }
        guard owned else { return "No owner" }
        if remaining < leaseSeconds / 3 { return "Renewal late" }
        return "Renewing"
    }

    /// Green while renewals keep up; orange once a third is left (clients renew
    /// by then); red in the last few seconds before ownership lapses.
    private func tint(_ remaining: Double) -> Color {
        guard owned, !recovering else { return .secondary }
        if remaining <= min(5, leaseSeconds / 6) { return .red }
        if remaining < leaseSeconds / 3 { return .orange }
        return .green
    }

    /// OTP-style digit groups of three: 1000042 → "1 000 042".
    static func grouped(_ term: Int64) -> String {
        let digits = Array(String(term))
        var groups: [String] = []
        var end = digits.count
        while end > 0 {
            let start = max(0, end - 3)
            groups.insert(String(digits[start..<end]), at: 0)
            end = start
        }
        return groups.joined(separator: " ")
    }
}

/// A Passwords-style countdown ring with the seconds remaining inside.
struct WitnessLeaseRing: View {
    let fraction: Double
    let seconds: Double?
    let tint: Color
    var size: CGFloat = 40
    var animatesCountdown = false

    var body: some View {
        ZStack {
            Circle().stroke(.primary.opacity(0.1), lineWidth: 3.5)
            Circle()
                .trim(from: 0, to: min(1, max(0, fraction)))
                .stroke(tint, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(animatesCountdown ? .linear(duration: 1) : nil, value: fraction)
            if let seconds {
                Text("\(Int(ceil(seconds)))")
                    .font(.system(size: size * 0.32, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(tint)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Creates a single-use pairing code and shows it like a one-time code, with a
/// ring counting down to its expiry. Requests from servers appear below it.
struct WitnessPairingPanel: View {
    @EnvironmentObject private var model: WitnessAppModel
    let service: GuardedService
    @State private var creating = false
    @State private var error: String?

    private var code: PairingDesk.Code? { model.pairingCodes.first { $0.clusterID == service.clusterID } }

    var body: some View {
        ConsoleSection(title: "Pair a Server", accessory: { Text("Single use") }, content: {
            VStack(alignment: .leading, spacing: 14) {
                if let code {
                    WitnessPairingCodeView(code: code) { Task { await model.cancelPairingCode(code.code) } }
                    Text("On the server, enter this Ruru’s address and the code. You’ll approve the request here before it receives any credentials.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack(alignment: .center, spacing: 12) {
                        Text("Pair without copying the token: create a code, enter it on the server, then approve the request here.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button(creating ? "Creating…" : "Create Code", systemImage: "number") {
                            creating = true
                            Task {
                                do { _ = try await model.createPairingCode(for: service.clusterID); error = nil }
                                catch { self.error = error.localizedDescription }
                                creating = false
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(creating || model.state != .running)
                    }
                    if model.state != .running {
                        Text("Start Ruru’s service to pair servers.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let error { ConsoleIssue(title: "Pairing code unavailable", detail: error) }
                WitnessPairingRequestList(service: service)
                Text("The server’s software must support Ruru pairing codes (RuruClient’s RuruPairing, or POST /v1/pair). Otherwise, use the details above.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        })
    }
}

struct WitnessPairingCodeView: View {
    let code: PairingDesk.Code
    let cancel: () -> Void
    @State private var anchor = (remaining: 0.0, at: Date())

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Pairing code").font(.callout).foregroundStyle(.secondary)
                Text(code.code.replacingOccurrences(of: "-", with: " "))
                    .font(.system(size: 30, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
                    .accessibilityLabel("Pairing code " + code.code.map(String.init).joined(separator: " "))
            }
            Spacer(minLength: 12)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = max(0, anchor.remaining - context.date.timeIntervalSince(anchor.at))
                HStack(spacing: 10) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Expires in \(Int(ceil(remaining / 60))) min").font(.callout.weight(.medium))
                        Button("Cancel Code", action: cancel).buttonStyle(.link).font(.caption)
                    }
                    WitnessLeaseRing(fraction: remaining / PairingDesk.codeLifetime, seconds: nil,
                                     tint: remaining < 60 ? .orange : .accentColor)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .consoleRowGroup()
        .onAppear { anchor = (code.expiresIn, Date()) }
        .onChange(of: code.code) { anchor = (code.expiresIn, Date()) }
    }
}

/// Servers paired with their own credential. Revoking one cuts off only that
/// server; it must pair again to return.
struct WitnessPairedServerList: View {
    @EnvironmentObject private var model: WitnessAppModel
    let service: GuardedService
    @State private var error: String?
    @State private var revoking: WitnessNodeToken?

    var body: some View {
        let nodes = model.pairedNodes[service.clusterID] ?? []
        VStack(spacing: 0) {
            ForEach(nodes, id: \.nodeID) { node in
                HStack(spacing: 12) {
                    ConsoleIconTile(symbol: "desktopcomputer", size: 34)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(node.name ?? "Unnamed server").font(.callout.weight(.semibold))
                        Text(node.nodeID).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Button("Revoke…", role: .destructive) { revoking = node }.buttonStyle(.bordered)
                }.padding(12)
                if node.nodeID != nodes.last?.nodeID { Divider().padding(.leading, 58) }
            }
        }.consoleRowGroup()
        if let error { ConsoleIssue(title: "Server could not be revoked", detail: error) }
        Color.clear.frame(height: 0).alert("Revoke this server?", isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }),
                                           presenting: revoking) { node in
            Button("Revoke", role: .destructive) {
                Task {
                    do { try await model.revokeNode(clusterID: service.clusterID, nodeID: node.nodeID); error = nil }
                    catch { self.error = error.localizedDescription }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { node in
            Text("\(node.name ?? node.nodeID) will stop working immediately and must be paired again.")
        }
    }
}

/// Servers waiting for approval. Approving releases this service's endpoint
/// details and bearer token to that server once.
struct WitnessPairingRequestList: View {
    @EnvironmentObject private var model: WitnessAppModel
    let service: GuardedService
    @State private var error: String?

    var body: some View {
        let requests = model.pairingRequests(for: service.clusterID)
        if !requests.isEmpty {
            VStack(spacing: 0) {
                ForEach(requests) { request in
                    HStack(spacing: 12) {
                        ConsoleIconTile(symbol: "desktopcomputer", size: 34)
                        VStack(alignment: .leading, spacing: 3) {
                            Text((request.nodeName ?? "Unnamed server") + " wants to pair").font(.callout.weight(.semibold))
                            Text(request.nodeID + " · " + (request.age < 60 ? "just now" : "\(Int(request.age / 60)) min ago"))
                                .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Button("Reject") { Task { await model.rejectPairing(request) } }.buttonStyle(.bordered)
                        Button("Approve") {
                            Task {
                                do { try await model.approvePairing(request); error = nil }
                                catch { self.error = error.localizedDescription }
                            }
                        }.buttonStyle(.borderedProminent)
                    }.padding(12)
                    if request.id != requests.last?.id { Divider().padding(.leading, 58) }
                }
            }.consoleRowGroup()
            Text("Only approve servers you just paired. Approving sends this service’s connection details and token to that server.")
                .font(.caption).foregroundStyle(.secondary)
        }
        if let error { ConsoleIssue(title: "Request could not be approved", detail: error) }
    }
}
