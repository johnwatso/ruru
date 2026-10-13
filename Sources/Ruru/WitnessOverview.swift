import AppKit
import SwiftUI
import WitnessKit

/// Ruru's local adaptation of SwiftBot's console Overview: Ruru's own state,
/// four capability summaries, guarded services and recent activity.
struct WitnessOverview: View {
    @EnvironmentObject private var model: WitnessAppModel
    @Environment(\.openSettings) private var openSettings
    let onNavigate: (WitnessPage) -> Void
    let onStop: () -> Void
    @State private var showingStorageSetup = false
    @State private var availableCardWidth: CGFloat = 0
    @State private var availableTableWidth: CGFloat = 0
    private let host = RuruHostInfo.current

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header.padding(.bottom, 4)
                summary
                summaryCards
                guardedServices
                recentActivity
            }
            .padding(.horizontal, 36).padding(.top, 32).padding(.bottom, 40)
            .frame(maxWidth: 1120, alignment: .leading).frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $showingStorageSetup) { WitnessLegacyStorageSetupSheet().environmentObject(model) }
    }

    private func perform(_ action: WitnessAppModel.Attention.Action) {
        switch action {
        case .continueSetup: model.showingSetup = true
        case .start: Task { await model.start() }
        case .setupStorage: showingStorageSetup = true
        case .page(let page): onNavigate(page)
        }
    }

    private func showSettings() {
        NSApplication.shared.activate()
        openSettings()
    }

    private var header: some View {
        ConsolePageHeader(title: "Overview", subtitle: "Ruru’s status, guarded services and recent activity at a glance.") {
            HStack(spacing: 12) {
                Menu {
                    if model.state == .running {
                        Button("Stop Service…", systemImage: "stop.fill", role: .destructive, action: onStop)
                        Divider()
                    }
                    Button("Run Setup Assistant…", systemImage: "wand.and.stars") { model.showingSetup = true }
                    Button("Show Data Folder in Finder", systemImage: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([WitnessStorage.directory])
                    }
                    Button("Settings", systemImage: "gearshape") { showSettings() }
                } label: { Label("More", systemImage: "wrench.and.screwdriver").labelStyle(.iconOnly) }
                .menuStyle(.button).menuIndicator(.hidden).fixedSize()
                .help("More").accessibilityLabel("More")
                Button(model.state == .running ? "Stop…" : "Start", systemImage: model.state == .running ? "stop.fill" : "play.fill") {
                    if model.state == .running { onStop() }
                    else { Task { await model.start() } }
                }
                .buttonStyle(.bordered).buttonBorderShape(.capsule)
                .disabled(model.busy || model.internetBusy || model.legacyStorageNeedsReplacement)
                .help(model.legacyStorageNeedsReplacement ? "Set up DuckDB before starting." : "Control the ownership service.")
                Button("Guarding", systemImage: "checkmark.shield") { onNavigate(.guarding) }
                    .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
            }
        }
    }

    // MARK: Ruru status

    /// Ruru's own operating condition, derived from authority state only. A held
    /// lease or a healthy participant does not enter into it.
    private var authority: (title: String, detail: String, health: WitnessHealth, symbol: String) {
        switch model.state {
        case .stopped:
            return ("Authority stopped", "Ruru is not currently accepting lease requests.", .inactive, "pause.circle.fill")
        case .starting:
            return ("Authority starting", "Ruru is starting its services.", .inactive, "hourglass.circle.fill")
        case .failed:
            return ("Authority requires attention", model.error ?? "An issue has been detected that may affect authority operation.",
                    .error, "exclamationmark.triangle.fill")
        case .running:
            if model.isRecovering {
                return ("Authority starting", "Ruru is waiting for earlier leases to expire before granting ownership.",
                        .warning, "hourglass.circle.fill")
            }
            let blockers = model.attentionItems.filter { $0.tier == .authority && $0.health != .inactive }
            if let first = blockers.first {
                return ("Authority requires attention", first.detail, first.health == .error ? .error : .warning,
                        "exclamationmark.triangle.fill")
            }
            return ("Authority operating normally", "Ruru is running and accepting lease requests.", .healthy, "checkmark.circle.fill")
        }
    }

    /// Issues beyond the authority line itself, each with the action that fixes it.
    private var otherIssues: [WitnessAppModel.Attention] {
        model.attentionItems.filter { $0.id != "recovery" && $0.id != "stopped" }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 20) {
                appIcon
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 10) {
                            Text("Ruru").font(.title.weight(.semibold))
                            WitnessStatusBadge(text: model.statusText, health: model.serviceHealth)
                        }
                        identityLine
                    }
                    let authority = authority
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: authority.symbol).foregroundStyle(authority.health == .inactive ? Color.secondary : authority.health.tint)
                            .font(.title3).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(authority.title).font(.headline)
                            Text(authority.detail).font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                Spacer(minLength: 0)
            }
            if !otherIssues.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(otherIssues) { item in
                        WitnessOverviewIssue(tier: item.tier.rawValue, title: item.title,
                                             detail: item.detail, health: item.health,
                                             reviewTitle: item.actionTitle) { perform(item.action) }
                    }
                }
            }
        }
        .padding(22).frame(maxWidth: .infinity, alignment: .leading)
        .consoleSurface(cornerRadius: 22)
    }

    private var appIcon: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable().interpolation(.high).frame(width: 76, height: 76)
            .accessibilityLabel("Ruru, \(model.statusText)")
    }

    private var identityLine: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            let location = model.state == .running ? "Running on \(host.computerName)" : "On \(host.computerName)"
            if model.state == .running, let started = model.serviceStartedAt {
                let uptime = started.duration(to: .now).formatted(.units(allowed: [.days, .hours, .minutes], width: .narrow, maximumUnitCount: 3))
                Text("\(location) · Uptime \(uptime)")
            } else {
                Text(location)
            }
        }
        .font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
    }

    // MARK: Summary cards

    private var summaryCards: some View {
        Group {
            if availableCardWidth == 0 || availableCardWidth >= 168 * 4 + 14 * 3 {
                HStack(alignment: .top, spacing: 14) { guardingCard; internetCard; activityCard; monitoringCard }
            } else {
                Grid(horizontalSpacing: 14, verticalSpacing: 14) {
                    GridRow { guardingCard; internetCard }
                    GridRow { activityCard; monitoringCard }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableCardWidth = $0 }
    }

    private func plural(_ count: Int, _ noun: String) -> String { "\(count) \(noun)\(count == 1 ? "" : "s")" }

    private var guardingCard: some View {
        let owners = model.activeServiceCount
        return WitnessServiceCard(title: "Guarding", symbol: "checkmark.shield",
                                  status: plural(model.configuration.guardedServices.count, "service"),
                                  detail: "\(owners) active owner\(owners == 1 ? "" : "s")",
                                  health: owners > 0 ? .healthy : .inactive) { onNavigate(.guarding) }
    }

    private var internetCard: some View {
        let endpoint = model.configuration.publicEndpoint
        let connected = model.internetHealth == .healthy
        let detail = endpoint.isEmpty ? "No public endpoint"
            : connected ? "Public endpoint available\n\(endpoint)" : endpoint
        return WitnessServiceCard(title: "Internet Access", symbol: "globe", brandAsset: "CloudflareLogo",
                                  status: model.internetStateText, detail: detail,
                                  health: model.internetHealth) { onNavigate(.internet) }
    }

    private var activityCard: some View {
        let count = model.snapshot?.events.count ?? 0
        return WitnessServiceCard(title: "Activity", symbol: "clock.arrow.circlepath",
                                  status: plural(count, "recent event"),
                                  detail: "Ownership transfers and releases", health: .inactive) { onNavigate(.activity) }
    }

    private var monitoringCard: some View {
        let targets = model.configuration.monitorTargets
        let active = targets.filter(\.enabled)
        let states = active.map { model.monitorStates[$0.id]?.status ?? .unknown }
        let failing = states.filter { $0 == .down }.count
        let checked = states.filter { $0 != .unknown }.count
        let status: String, detail: String, health: WitnessHealth
        if targets.isEmpty {
            (status, detail, health) = ("No endpoints", "Watch servers and addresses", .inactive)
        } else if active.isEmpty {
            (status, detail, health) = (plural(targets.count, "endpoint"), "All endpoints paused", .inactive)
        } else if failing > 0 {
            (status, detail, health) = (plural(active.count, "endpoint"),
                                        "\(failing) \(failing == 1 ? "check" : "checks") failing\nActive incidents detected", .error)
        } else if checked < active.count {
            (status, detail, health) = (plural(active.count, "endpoint"), "Waiting for first checks", .inactive)
        } else {
            (status, detail, health) = (plural(active.count, "endpoint"), "All checks passing\nNo active incidents", .healthy)
        }
        return WitnessServiceCard(title: "Monitoring", symbol: "waveform.path.ecg", status: status,
                                  detail: detail, health: health) { onNavigate(.monitoring) }
    }

    // MARK: Guarded services

    private func open(_ service: GuardedService) {
        model.pendingGuardedServiceID = service.id
        onNavigate(.guarding)
    }

    private var guardedServices: some View {
        ConsoleSection(title: "Guarded Services", padding: 18, accessory: {
            Button("Manage Services") { onNavigate(.guarding) }.buttonStyle(.borderless).foregroundStyle(Color.accentColor)
        }, content: {
            let services = model.configuration.guardedServices
            let wide = availableTableWidth == 0 || availableTableWidth >= 560
            if services.isEmpty {
                ConsoleEmptyState(symbol: "checkmark.shield", title: "No guarded services",
                                  detail: "Add an app in Guarding to coordinate it with Ruru.")
            } else {
                VStack(spacing: 0) {
                    if wide { tableHeader }
                    ForEach(services) { service in
                        Button { open(service) } label: { serviceRow(service, wide: wide) }
                            .buttonStyle(.plain).accessibilityHint("Shows \(service.name) in Guarding")
                        if service.id != services.last?.id { Divider() }
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableTableWidth = $0 }
            }
        })
    }

    private static let participantsWidth: CGFloat = 120
    private static let statusWidth: CGFloat = 150

    private var tableHeader: some View {
        HStack(spacing: 12) {
            Text("Service").frame(maxWidth: .infinity, alignment: .leading)
            Text("Ownership").frame(maxWidth: .infinity, alignment: .leading)
            Text("Participants").frame(width: Self.participantsWidth, alignment: .leading)
            Text("Status").frame(width: Self.statusWidth, alignment: .leading)
            Color.clear.frame(width: 10)
        }
        .font(.caption.weight(.medium)).foregroundStyle(.secondary).padding(.bottom, 8)
        .accessibilityHidden(true)
    }

    private func owner(_ service: GuardedService) -> (name: String, owned: Bool) {
        let name = model.guardOwner(for: service.clusterID)
        return (name, (model.lease(for: service.clusterID)?.remainingSeconds ?? 0) > 0)
    }

    private func participants(_ service: GuardedService) -> String {
        let count = model.knownNodes(for: service.clusterID).count
        return count == 0 ? "None known" : "\(count) known \(count == 1 ? "node" : "nodes")"
    }

    @ViewBuilder private func serviceRow(_ service: GuardedService, wide: Bool) -> some View {
        let status = model.overviewStatus(for: service.clusterID)
        let owner = owner(service)
        let ownership = HStack(spacing: 8) {
            Image(systemName: owner.owned ? "desktopcomputer" : "circle.dashed").foregroundStyle(owner.owned ? Color.accentColor : .secondary)
                .accessibilityHidden(true)
            Text(owner.name).foregroundStyle(owner.owned ? .primary : .secondary).lineLimit(1).truncationMode(.tail)
        }
        let statusLabel = Label { Text(status.text).lineLimit(1) } icon: {
            Circle().fill(status.health.tint).frame(width: 7, height: 7).accessibilityHidden(true)
        }
        let chevron = Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        Group {
            if wide {
                HStack(spacing: 12) {
                    HStack(spacing: 10) {
                        WitnessGuardedServiceIcon(service: service, active: status.health != .inactive, size: 32)
                        Text(service.name).font(.callout.weight(.medium)).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    ownership.frame(maxWidth: .infinity, alignment: .leading)
                    Text(participants(service)).foregroundStyle(.secondary).lineLimit(1)
                        .frame(width: Self.participantsWidth, alignment: .leading)
                    statusLabel.frame(width: Self.statusWidth, alignment: .leading)
                    chevron.frame(width: 10)
                }
            } else {
                HStack(spacing: 10) {
                    WitnessGuardedServiceIcon(service: service, active: status.health != .inactive, size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(service.name).font(.callout.weight(.medium)).lineLimit(1)
                        Text("\(owner.name) · \(participants(service))").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    statusLabel
                    chevron
                }
            }
        }
        .font(.callout).padding(.vertical, 8).contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    // MARK: Recent activity

    private var recentActivity: some View {
        ConsoleSection(title: "Recent Activity", padding: 18, accessory: {
            Button("View All") { onNavigate(.activity) }.buttonStyle(.borderless).foregroundStyle(Color.accentColor)
        }, content: {
            let items = model.activityFeed(limit: 5)
            if items.isEmpty {
                ConsoleEmptyState(symbol: "clock", title: "Nothing yet", detail: "Ownership changes and server reports appear here as your servers connect.")
            } else {
                ActivityFeedList(items: items)
            }
        })
    }
}

private struct WitnessOverviewIssue: View {
    var tier: String = ""
    let title: String
    let detail: String
    let health: WitnessHealth
    var reviewTitle = "Review"
    let onReview: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { message; Spacer(minLength: 16); review }
            VStack(alignment: .leading, spacing: 12) { message; review }
        }
        .padding(.leading, 24).padding(.trailing, 14).padding(.vertical, 10)
        .background(health.tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(tier.isEmpty ? "" : "\(tier): ")\(title). \(detail)")
    }
    private var message: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: health.symbol)
                .font(.system(size: 22)).foregroundStyle(health == .inactive ? .orange : health.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if !tier.isEmpty {
                        Text(tier).font(.caption.weight(.semibold)).foregroundStyle(health.tint)
                            .textCase(.uppercase).accessibilityHidden(true)
                        Text("—").font(.caption).foregroundStyle(.tertiary).accessibilityHidden(true)
                    }
                    Text(title).font(.callout.weight(.semibold))
                }
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private var review: some View {
        Button(reviewTitle, action: onReview).buttonStyle(.bordered).buttonBorderShape(.capsule)
            .accessibilityLabel(reviewTitle == "Review" ? "Review \(title)" : reviewTitle)
    }
}


/// Read-only facts about this Mac and build, shown in Settings → General.
struct RuruHostInfo {
    let computerName: String
    let architecture: String
    let memory: String
    let operatingSystem: String
    let version: String
    let build: String

    static let current: Self = {
        #if arch(arm64)
        let architecture = "Apple silicon (arm64)"
        #else
        let architecture = "Intel (x86_64)"
        #endif
        let info = Bundle.main.infoDictionary ?? [:]
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return Self(computerName: Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
                    architecture: architecture,
                    memory: ByteCountFormatter.string(fromByteCount: Int64(ProcessInfo.processInfo.physicalMemory), countStyle: .memory),
                    operatingSystem: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
                    version: info["CFBundleShortVersionString"] as? String ?? "—",
                    build: info["CFBundleVersion"] as? String ?? "—")
    }()
}
