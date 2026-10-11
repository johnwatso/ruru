import AppKit
import SwiftUI

/// Ruru's local adaptation of SwiftBot's current console Overview.
struct WitnessOverview: View {
    @EnvironmentObject private var model: WitnessAppModel
    @Environment(\.openSettings) private var openSettings
    let onNavigate: (WitnessPage) -> Void
    let onStop: () -> Void
    @State private var showingStorageSetup = false
    @State private var availableServiceWidth: CGFloat = 0
    private let host = WitnessOverviewHost.current

    private var headline: String {
        if model.isRecovering { return "Waiting for earlier ownership to expire." }
        switch model.state {
        case .running: return ""
        case .starting: return "Starting the ownership service."
        case .stopped: return "Ruru is stopped on this Mac."
        case .failed: return "Ruru needs attention before it can run."
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                header.padding(.bottom, 4)
                summary
                services
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 28) {
                        quickActions.frame(minWidth: 280, maxWidth: .infinity)
                        systemDetails.frame(minWidth: 340, maxWidth: .infinity)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 32) {
                        quickActions
                        systemDetails
                    }
                }
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
        ConsolePageHeader(title: "Overview", subtitle: headline) {
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

    private var summary: some View {
        VStack(alignment: .leading, spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 26) {
                    appIcon
                    summaryIdentity.frame(minWidth: 320, maxWidth: .infinity, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 18) { appIcon; summaryIdentity }
            }.padding(28)

            if !model.attentionItems.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.attentionItems) { item in
                        WitnessOverviewIssue(tier: item.tier.rawValue, title: item.title,
                                             detail: item.detail, health: item.health,
                                             reviewTitle: item.actionTitle) { perform(item.action) }
                    }
                }.padding(.horizontal, 16).padding(.bottom, 16).padding(.top, -8)
            }
        }.consoleSurface(cornerRadius: 22)
    }

    private var appIcon: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable().interpolation(.high).frame(width: 108, height: 108)
            .accessibilityLabel("Ruru, \(model.statusText)")
    }

    private var summaryIdentity: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 12) {
                    Text("Ruru").font(.title.weight(.semibold))
                    WitnessStatusBadge(text: model.statusText, health: model.serviceHealth)
                }
                Text("Service authority · \(host.buildChannel)").font(.title3).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 24) {
                fact("Version") { Text(host.version) }
                Divider()
                fact("Node") { Text(host.computerName).help(host.computerName) }
                Divider()
                fact("Uptime") {
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        if let started = model.serviceStartedAt {
                            Text(started.duration(to: .now).formatted(.units(allowed: [.days, .hours, .minutes], width: .narrow, maximumUnitCount: 3)))
                                .monospacedDigit()
                        } else { Text("—").foregroundStyle(.secondary) }
                    }
                }
            }.fixedSize(horizontal: false, vertical: true)
        }
    }

    private func fact<Value: View>(_ title: String, @ViewBuilder value: () -> Value) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            value().font(.title3.weight(.medium)).lineLimit(1).truncationMode(.middle)
        }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
    }

    private var services: some View {
        ConsoleSection(title: "Services", accessory: { Text(model.guardingSummary) }, content: {
            Group {
                if availableServiceWidth == 0 || availableServiceWidth >= 168 * 4 + 14 * 3 {
                    HStack(alignment: .top, spacing: 14) { guardingCard; internetCard; activityCard; alertsCard }
                } else {
                    Grid(horizontalSpacing: 14, verticalSpacing: 14) {
                        GridRow { guardingCard; internetCard }
                        GridRow { activityCard; alertsCard }
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableServiceWidth = $0 }
        })
    }

    private var guardingCard: some View {
        WitnessServiceCard(title: "Guarding", symbol: "server.rack", status: "\(model.configuration.guardedServices.count) \(model.configuration.guardedServices.count == 1 ? "service" : "services")",
                           detail: "\(model.activeServiceCount) with an owner", health: model.activeServiceCount > 0 ? .healthy : .inactive) { onNavigate(.guarding) }
    }
    private var internetCard: some View {
        WitnessServiceCard(title: "Internet Access", symbol: "globe", brandAsset: "CloudflareLogo", status: model.internetStateText,
                           detail: model.configuration.publicEndpoint.isEmpty ? "Choose a public address" : model.configuration.publicEndpoint,
                           health: model.internetHealth) { onNavigate(.internet) }
    }
    private var activityCard: some View {
        WitnessServiceCard(title: "Activity", symbol: "clock.arrow.circlepath", status: "\(model.snapshot?.events.count ?? 0) events",
                           detail: "Ownership transfers and releases", health: .inactive) { onNavigate(.activity) }
    }

    private var quickActions: some View {
        ConsoleSection("Quick Actions", padding: 14, headerInset: 10, fillsAvailableHeight: true) {
            VStack(spacing: 0) {
                ConsoleActionRow(title: "Manage Services", subtitle: "Ownership, servers and connection details", symbol: "checkmark.shield") { onNavigate(.guarding) }
                Divider().padding(.leading, 42)
                ConsoleActionRow(title: "Internet Access", subtitle: "Manage this Mac’s Cloudflare tunnel", symbol: "globe") { onNavigate(.internet) }
                Divider().padding(.leading, 42)
                ConsoleActionRow(title: "View Activity", subtitle: "Recent ownership transfers and releases", symbol: "doc.text.magnifyingglass") { onNavigate(.activity) }
            }
        }
    }

    private var systemDetails: some View {
        ConsoleSection("System", fillsAvailableHeight: true) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 18, verticalSpacing: 14) {
                systemRow("Computer", symbol: "desktopcomputer", value: host.computerName)
                systemRow("Architecture", symbol: "cpu", value: host.architecture)
                systemRow("Memory", symbol: "memorychip", value: host.memory)
                systemRow("macOS", symbol: "apple.logo", value: host.operatingSystem)
                systemRow("Ruru", symbol: "app.badge", value: "\(host.version) (\(host.build))")
                systemRow("Storage", symbol: "externaldrive", value: model.legacyStorageNeedsReplacement ? "SQLite · setup required" : "DuckDB")
            }
        }
    }

    private func systemRow(_ title: String, symbol: String, value: String) -> some View {
        GridRow {
            Label { Text(title) } icon: { Image(systemName: symbol).foregroundStyle(.tertiary).frame(width: 18) }
                .foregroundStyle(.secondary).gridColumnAlignment(.leading)
            Text(value).lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(value)
                .frame(maxWidth: .infinity, alignment: .leading)
        }.accessibilityElement(children: .combine)
    }

    private var alertsCard: some View {
        WitnessServiceCard(title: "Alerts", symbol: "bell.badge",
                           status: model.alertsStatusText,
                           detail: model.alertDeliveryError ?? "Service and authority notifications",
                           health: model.alertsHealth) { showSettings() }
    }

    private var recentActivity: some View {
        ConsoleSection(title: "Recent Activity", accessory: {
            Button("View All") { onNavigate(.activity) }.buttonStyle(.borderless)
        }, content: {
            if let events = model.snapshot?.events, !events.isEmpty {
                VStack(spacing: 0) {
                    ForEach(events.prefix(3)) { event in
                        WitnessEventRow(event: event, compact: true)
                        if event.id != events.prefix(3).last?.id { Divider().padding(.leading, 42) }
                    }
                }
            } else {
                ConsoleEmptyState(symbol: "clock", title: "No transfers yet", detail: "Ownership changes appear here as your servers connect.")
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


private struct WitnessOverviewHost {
    let computerName: String
    let architecture: String
    let memory: String
    let operatingSystem: String
    let version: String
    let build: String
    let buildChannel: String

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
                    build: info["CFBundleVersion"] as? String ?? "—",
                    buildChannel: "Development preview")
    }()
}
