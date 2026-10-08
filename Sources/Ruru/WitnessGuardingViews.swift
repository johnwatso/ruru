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
    let service: GuardedService
    var active = true
    var size: CGFloat = 42

    var body: some View {
        if let asset = service.brandAsset {
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
    private var nodes: [String] { model.knownNodes(for: service.clusterID) }
    private var events: [WitnessEvent] { model.events(for: service.clusterID) }

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
        if !model.pairingRequests(for: service.clusterID).isEmpty {
            ConsoleSection(title: "Pairing Requests", accessory: { Text("Expire after 10 minutes") }, content: {
                WitnessPairingRequestList(service: service)
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
                    Text("The term is the fencing token servers attach to their work; it only ever increases. The ring shows how long the current grant lasts without another renewal, and refills each time the owner renews.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Connect this service’s servers using its connection details. Any number of participants can compete; one holds ownership at a time.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        })
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
            preferredPrimaryRow
            if let preferenceError { ConsoleIssue(title: "Preference could not be saved", detail: preferenceError) }
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
                        do { try await model.addGuardedService(name: name, clusterID: clusterID, kind: kind, leaseSeconds: leaseSeconds); dismiss() }
                        catch { self.error = error.localizedDescription; saving = false }
                    }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!valid || saving || model.busy)
            }
        }.padding(24).frame(width: 560).interactiveDismissDisabled(saving)
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
    init(service: GuardedService) {
        self.service = service
        _name = State(initialValue: service.name)
        _leaseSeconds = State(initialValue: service.leaseSeconds)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Edit Service").font(.title2.weight(.semibold))
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
                        do { try await model.updateService(id: service.id, name: name, leaseSeconds: leaseSeconds); dismiss() }
                        catch { self.error = error.localizedDescription; saving = false }
                    }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(WitnessNodeName.normalized(name) == nil || name.utf8.count > 128 || saving || model.busy)
            }
        }.padding(24).frame(width: 460).interactiveDismissDisabled(saving)
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

/// The lease shown like a one-time code: the ownership term in grouped digits
/// with a countdown ring for the current grant. Ruru polls once a second; the
/// ring interpolates between polls so it drains smoothly.
struct WitnessLeaseCode: View {
    let lease: LeaseStatus?
    let leaseSeconds: Double
    var recovering = false
    @State private var anchor = (remaining: 0.0, at: Date.distantPast)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var owned: Bool { (lease?.remainingSeconds ?? 0) > 0 }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Ownership term").font(.callout).foregroundStyle(.secondary)
                Text(Self.grouped(lease?.term ?? 0))
                    .font(.system(size: 30, weight: .semibold, design: .monospaced))
                    .foregroundStyle(owned ? .primary : .secondary)
                    .contentTransition(.numericText(value: Double(lease?.term ?? 0)))
                    .animation(reduceMotion ? nil : .snappy, value: lease?.term)
                    .textSelection(.enabled)
                    .accessibilityLabel("Ownership term \(lease?.term ?? 0)")
            }
            Spacer(minLength: 12)
            TimelineView(.periodic(from: .now, by: reduceMotion ? 1 : 1.0 / 30)) { context in
                let remaining = max(0, anchor.remaining - context.date.timeIntervalSince(anchor.at))
                HStack(spacing: 10) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(caption(remaining)).font(.callout.weight(.medium)).foregroundStyle(tint(remaining))
                        Text("\(Int(leaseSeconds)) s lease").font(.caption).foregroundStyle(.secondary)
                    }
                    WitnessLeaseRing(fraction: owned ? remaining / leaseSeconds : 0, seconds: owned ? remaining : nil,
                                     tint: tint(remaining))
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(owned ? "\(Int(ceil(remaining))) seconds left in this grant" : caption(remaining))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .consoleRowGroup()
        .onAppear(perform: resetAnchor)
        .onChange(of: lease?.remainingSeconds) { resetAnchor() }
    }

    private func resetAnchor() { anchor = (lease?.remainingSeconds ?? 0, Date()) }

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

    var body: some View {
        ZStack {
            Circle().stroke(.primary.opacity(0.1), lineWidth: 3.5)
            Circle()
                .trim(from: 0, to: min(1, max(0, fraction)))
                .stroke(tint, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
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
