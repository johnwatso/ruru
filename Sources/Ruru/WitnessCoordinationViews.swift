import SwiftUI
import WitnessKit

struct WitnessCoordinationPage: View {
    @EnvironmentObject private var model: WitnessAppModel
    @State private var selectedID: String?
    @State private var adding = false

    private var selected: GuardedService? {
        model.configuration.guardedServices.first { $0.id == selectedID }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if let selected {
                    WitnessCoordinationServiceDetails(service: selected) { selectedID = nil }
                        .id(selected.id)
                } else {
                    ConsolePageHeader(title: "Coordination", subtitle: "Choose an app or service to manage its coordination.") {
                        Button("Add Service", systemImage: "plus") { adding = true }
                            .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                            .disabled(model.busy || model.internetBusy || model.configuration.guardedServices.count >= 32)
                    }
                    if model.configuration.guardedServices.isEmpty {
                        ConsoleEmptyState(symbol: "server.rack", title: "Add your first app or service",
                            detail: "Each service gets its own coordination settings, server reports and resources.")
                    } else {
                        ForEach(model.configuration.guardedServices) { service in
                            serviceCard(service)
                        }
                    }
                    Text("Coordination features are configured separately for each service. The same service can also use ownership guarding.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 36).padding(.top, 32).padding(.bottom, 40)
            .frame(maxWidth: 1120, alignment: .leading).frame(maxWidth: .infinity, alignment: .top)
        }
        .sheet(isPresented: $adding) {
            WitnessAddServiceSheet(subtitle: "Connect an app or service with its own coordination group.", symbol: "server.rack")
                .environmentObject(model)
        }
    }

    private func serviceCard(_ service: GuardedService) -> some View {
        let policy = model.configuration.coordinationPolicy(for: service.id)
        let locations = model.coordinationLocations.filter { $0.clusterID == service.clusterID }
        let requests = model.coordinationEnrollments.filter { $0.clusterID == service.clusterID }.count
        let resourceCount = Set(locations.map { CoordinationResourceKey(namespace: $0.resource.namespace, resourceID: $0.resource.resourceID) }).count
        let serverCount = Set(locations.map(\.nodeID)).count
        let resourceLabel = resourceCount == 1 ? "1 resource" : "\(resourceCount) resources"
        let serverLabel = serverCount == 1 ? "1 server" : "\(serverCount) servers"
        let locationLabel = locations.count == 1 ? "1 location" : "\(locations.count) locations"
        return Button { selectedID = service.id } label: {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 16) {
                    WitnessGuardedServiceIcon(service: service, size: 48)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(service.name).font(.title3.weight(.semibold))
                        Text(service.kind.rawValue).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right").font(.callout.weight(.semibold)).foregroundStyle(.tertiary)
                }
                HStack(spacing: 12) {
                    Label("Resource catalogue", systemImage: "square.stack.3d.up").font(.callout.weight(.medium))
                    WitnessStatusBadge(text: policy.enabled ? "Enabled" : "Not enabled", health: policy.enabled ? .healthy : .inactive)
                }
                Text(policy.enabled ? resourceLabel + " · " + serverLabel + " · " + locationLabel : "Set up resource reporting for this service’s servers.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if requests > 0 {
                    Label(requests == 1 ? "1 website awaiting approval" : "\(requests) websites awaiting approval",
                          systemImage: "person.crop.circle.badge.clock")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(22).frame(maxWidth: .infinity, alignment: .leading).consoleSurface()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityHint("Shows coordination settings and resources for " + service.name)
    }
}

private struct WitnessCoordinationServiceDetails: View {
    @EnvironmentObject private var model: WitnessAppModel
    let service: GuardedService
    let onBack: () -> Void
    @State private var editing = false
    @State private var connecting = false
    @State private var search = ""
    @State private var confirmingRemoval = false
    @State private var removalError: String?
    @State private var enrollmentError: String?
    @State private var processingEnrollment = false

    private var policy: CoordinationPolicy { model.configuration.coordinationPolicy(for: service.id) }
    private var locations: [CoordinationLocation] {
        model.coordinationLocations.filter {
            $0.clusterID == service.clusterID && (search.isEmpty ||
                [$0.resource.title, $0.resource.namespace, $0.resource.resourceID, $0.nodeID,
                 model.nodeDisplayName(for: $0.nodeID, reportedName: $0.nodeName, clusterID: service.clusterID)]
                    .contains { $0.localizedCaseInsensitiveContains(search) })
        }
    }

    var body: some View {
        Button("Coordination", systemImage: "chevron.left", action: onBack).buttonStyle(.borderless)
        HStack(spacing: 16) {
            WitnessGuardedServiceIcon(service: service, size: 48)
            ConsolePageHeader(title: service.name, subtitle: "Coordination settings and resources for this service.") {
                HStack(spacing: 10) {
                    Button("Remove…", systemImage: "trash", role: .destructive) { confirmingRemoval = true }
                        .buttonStyle(.bordered).buttonBorderShape(.capsule)
                        .disabled(model.busy || model.internetBusy)
                    Button("Connection Details", systemImage: "link") { connecting = true }
                        .buttonStyle(.bordered).buttonBorderShape(.capsule)
                }
            }
        }
        if let removalError { ConsoleIssue(title: "Service could not be removed", detail: removalError) }
        if let enrollmentError { ConsoleIssue(title: "Website request could not be approved", detail: enrollmentError) }
        let requests = model.coordinationEnrollments.filter { $0.clusterID == service.clusterID }
        if !requests.isEmpty {
            ConsoleSection("Website requests") {
                Text("Servers paired with this service can request sharing access. Approving allows resources from the exact website shown below.")
                    .font(.callout).foregroundStyle(.secondary)
                ForEach(requests) { request in
                    ConsoleSettingRow(title: request.nodeName ?? request.nodeID, subtitle: request.origin) {
                        HStack {
                            Button("Reject") {
                                processingEnrollment = true
                                Task { await model.rejectCoordinationEnrollment(id: request.id); processingEnrollment = false }
                            }
                            Button(policy.enabled ? "Approve" : "Enable & Approve") {
                                processingEnrollment = true
                                enrollmentError = nil
                                Task {
                                    do { try await model.approveCoordinationEnrollment(id: request.id, serviceID: service.id) }
                                    catch { enrollmentError = error.localizedDescription }
                                    processingEnrollment = false
                                }
                            }
                            .disabled(policy.allowedOrigins.count >= 8 && !policy.allowedOrigins.contains(request.origin))
                        }
                        .disabled(processingEnrollment || model.busy || model.internetBusy)
                    }
                    .help("Reported node ID: " + request.nodeID + ". Received \(Int(request.ageSeconds)) seconds ago.")
                    .consoleRowGroup()
                }
                if policy.allowedOrigins.count >= 8 {
                    Text("Eight websites are already allowed. Remove one in Resource catalogue settings before approving another.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        ConsoleSection(title: "Resource catalogue", accessory: {
            WitnessStatusBadge(text: policy.enabled ? "Enabled" : "Not enabled", health: policy.enabled ? .healthy : .inactive)
        }) {
            ConsoleSettingRow(title: "Resource reporting", subtitle: "Keep a directory of resources and the servers that host them.") {
                Button("Settings…", systemImage: "slider.horizontal.3") { editing = true }
                    .disabled(model.busy || model.internetBusy)
            }.consoleRowGroup()
            if !policy.allowedOrigins.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Allowed server origins").font(.callout.weight(.medium))
                    ForEach(policy.allowedOrigins, id: \.self) { origin in
                        Text(origin).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
            Text("\(service.name)’s servers host and serve their own resources. Reporting does not change ownership.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        ConsoleSection(title: "Resource locations", accessory: { Text("\(locations.count) reported") }) {
            TextField("Search this service’s resources or servers", text: $search).textFieldStyle(.roundedBorder)
            if !policy.enabled {
                ConsoleEmptyState(symbol: "square.stack.3d.up", title: "Enable resource reporting for \(service.name)",
                    detail: "Open Resource catalogue settings to choose the origins its servers can advertise.")
            } else if locations.isEmpty {
                ConsoleEmptyState(symbol: "tray", title: search.isEmpty ? "Waiting for \(service.name)’s reports" : "No matching resources",
                    detail: search.isEmpty ? "Connect a compatible client to report this service’s resources and locations." : "Try a resource name, namespace or server.")
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(locations.prefix(100))) { location in
                        locationRow(location)
                        Divider()
                    }
                }
                if locations.count > 100 {
                    Text("Showing the first 100 locations. Use search to narrow the catalogue.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        Text("Fresh means reported within 90 seconds; reachability has not been checked. Stale locations disappear after 10 minutes. The catalogue starts empty after Ruru restarts.")
            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        .sheet(isPresented: $editing) {
            WitnessCoordinationPolicySheet(service: service, policy: policy).environmentObject(model)
        }
        .sheet(isPresented: $connecting) {
            ConnectionDetailsSheet(clusterID: service.clusterID).environmentObject(model)
        }
        .confirmationDialog("Remove \(service.name)?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button("Remove Service", role: .destructive) {
                Task {
                    do { try await model.removeGuardedService(id: service.id); onBack() }
                    catch { removalError = error.localizedDescription }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Removes this service from Coordination and Guarding and clears its reported locations. Its servers can no longer report resources or acquire/renew ownership; existing permission expires within 30 seconds. Hosted files, ownership terms and history are retained. Other services continue running.")
        }
    }

    private func locationRow(_ location: CoordinationLocation) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ConsoleIconTile(symbol: "doc", size: 36)
            VStack(alignment: .leading, spacing: 5) {
                Text(location.resource.title).font(.callout.weight(.semibold))
                Text(location.resource.namespace + " · " + location.resource.resourceID)
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Text(model.nodeDisplayName(for: location.nodeID, reportedName: location.nodeName, clusterID: location.clusterID))
                    .font(.callout).foregroundStyle(.secondary).help("Node ID: " + location.nodeID)
                Text(location.resource.url).font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                WitnessStatusBadge(text: location.fresh ? "Fresh report" : "Stale report", health: location.fresh ? .healthy : .warning)
                Text("\(Int(location.ageSeconds))s ago").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Button("Copy URL", systemImage: "doc.on.doc") { model.copy(location.resource.url) }
                    .font(.caption)
            }
        }.padding(.vertical, 14)
    }
}

private struct WitnessCoordinationPolicySheet: View {
    @EnvironmentObject private var model: WitnessAppModel
    @Environment(\.dismiss) private var dismiss
    let service: GuardedService
    @State private var enabled: Bool
    @State private var origins: String
    @State private var saving = false
    @State private var error: String?

    init(service: GuardedService, policy: CoordinationPolicy) {
        self.service = service
        _enabled = State(initialValue: policy.enabled)
        _origins = State(initialValue: policy.allowedOrigins.joined(separator: "\n"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Resource catalogue · \(service.name)").font(.title2.weight(.semibold))
            Toggle("Enable resource catalogue", isOn: $enabled)
            Text("Allowed server origins").font(.callout.weight(.medium))
            TextEditor(text: $origins).font(.system(.callout, design: .monospaced))
                .frame(height: 110).padding(6).consoleRowGroup()
            Text("One HTTPS origin per line, for example https://videos.example.com. Up to eight origins; omit paths, queries and credentials. An enabled catalogue can report only locations at these origins.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Disabling clears reported locations. Servers retain their files and continue using the existing lease protocol.")
                .font(.callout).foregroundStyle(.secondary)
            if let error { Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { Task { await save() } }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 530).disabled(saving)
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            let lines = origins.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let normalized = try lines.map { value in
                guard let origin = CoordinationPolicy.normalizedOrigin(value) else { throw WitnessStorage.ConfigurationError.invalidCoordinationPolicy }
                return origin
            }
            let policy = CoordinationPolicy(enabled: enabled, allowedOrigins: normalized)
            try await model.setCoordinationPolicy(policy, for: service.id)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
