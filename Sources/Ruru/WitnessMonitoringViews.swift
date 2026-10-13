import RuruAlerting
import SwiftUI
import WitnessKit

extension MonitorTarget {
    var symbol: String { kind == .tcp ? "point.3.connected.trianglepath.dotted" : "globe" }
}

extension WitnessAppModel {
    func monitorHealth(_ target: MonitorTarget) -> WitnessHealth {
        guard target.enabled else { return .inactive }
        switch monitorStates[target.id]?.status ?? .unknown {
        case .up: return .healthy
        case .down: return .error
        case .unknown: return .inactive
        }
    }
    func monitorStatusText(_ target: MonitorTarget) -> String {
        guard target.enabled else { return "Paused" }
        switch monitorStates[target.id]?.status ?? .unknown {
        case .up: return "Up"
        case .down: return "Down"
        case .unknown: return "Checking…"
        }
    }
    var monitoringSummary: String {
        let count = configuration.monitorTargets.count
        guard count > 0 else { return "No targets" }
        let down = monitorDownCount
        return "\(count) \(count == 1 ? "target" : "targets")" + (down > 0 ? " · \(down) down" : "")
    }
}

/// A target's custom icon, or the template tile for its check type.
private struct WitnessMonitorTargetIcon: View {
    @EnvironmentObject private var model: WitnessAppModel
    let target: MonitorTarget
    var size: CGFloat = 42

    var body: some View {
        let active = model.monitorHealth(target) == .healthy
        if let custom = model.serviceIcons[target.id] {
            Image(nsImage: custom).resizable().interpolation(.high).scaledToFit()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
                .saturation(active ? 1 : 0).opacity(model.monitorHealth(target) == .inactive ? 0.55 : 1)
                .accessibilityHidden(true)
        } else {
            ConsoleIconTile(symbol: target.symbol, active: active, size: size)
        }
    }
}

struct WitnessMonitoringPage: View {
    @EnvironmentObject private var model: WitnessAppModel
    @State private var adding = false
    @State private var selectedID: String?

    private var selected: MonitorTarget? { model.configuration.monitorTargets.first { $0.id == selectedID } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                ConsolePageHeader(title: "Monitoring", subtitle: "Check that servers and addresses on your network are reachable.") {
                    Button("Add Target", systemImage: "plus") { adding = true }
                        .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                        .disabled(model.configuration.monitorTargets.count >= MonitorTarget.maxTargets)
                }
                ConsoleSection(title: "Targets", accessory: { Text(model.monitoringSummary) }, content: {
                    if model.configuration.monitorTargets.isEmpty {
                        ConsoleEmptyState(symbol: "waveform.path.ecg", title: "Nothing monitored yet",
                                          detail: "Add a server, router or web address. Ruru checks it on a schedule and tells you when it stops answering.")
                    } else {
                        VStack(spacing: 0) {
                            ForEach(model.configuration.monitorTargets) { target in
                                Button { selectedID = target.id } label: { WitnessMonitorRow(target: target) }
                                    .buttonStyle(.plain).accessibilityHint("Shows check history and settings")
                                if target.id != model.configuration.monitorTargets.last?.id { Divider().padding(.leading, 64) }
                            }
                        }.consoleRowGroup()
                    }
                })
                Label("Monitoring only observes. It never changes ownership, and a down target does not affect failover.",
                      systemImage: "eye").font(.callout).foregroundStyle(.secondary)
            }.padding(.horizontal, 36).padding(.top, 32).padding(.bottom, 40)
                .frame(maxWidth: 1120, alignment: .leading).frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $adding) { WitnessMonitorTargetSheet(target: nil).environmentObject(model) }
        .sheet(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selectedID = nil } })) {
            if let selected { WitnessMonitorDetailSheet(target: selected).environmentObject(model).id(selected.id) }
        }
    }
}

private struct WitnessMonitorRow: View {
    @EnvironmentObject private var model: WitnessAppModel
    let target: MonitorTarget

    var body: some View {
        let state = model.monitorStates[target.id]
        HStack(spacing: 14) {
            WitnessMonitorTargetIcon(target: target)
            VStack(alignment: .leading, spacing: 5) {
                Text(target.name).font(.headline)
                Text(subtitle(state)).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            WitnessMonitorHistoryBar(results: state?.history ?? [], count: 30).frame(width: 120, height: 22)
                .accessibilityHidden(true)
            WitnessStatusBadge(text: model.monitorStatusText(target), health: model.monitorHealth(target))
                .frame(width: 104, alignment: .trailing)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }.padding(16).contentShape(Rectangle())
    }

    private func subtitle(_ state: MonitorState?) -> String {
        var parts = [target.kind.rawValue, target.address]
        if let last = state?.last {
            parts.append(last.ok ? (last.latencyMilliseconds.map { "\($0) ms" } ?? last.detail) : last.detail)
        }
        return parts.joined(separator: " · ")
    }
}

/// Newest results on the right: green for up, red for down, grey when empty.
struct WitnessMonitorHistoryBar: View {
    let results: [MonitorResult]
    let count: Int

    var body: some View {
        let recent = Array(results.suffix(count))
        HStack(spacing: 2) {
            ForEach(0..<count, id: \.self) { slot in
                let index = slot - (count - recent.count)
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(index < 0 ? Color.primary.opacity(0.08) : recent[index].inconclusive ? Color.gray.opacity(0.55) : recent[index].ok ? Color.green : Color.red)
                    .help(index < 0 ? "" : "\(recent[index].time.formatted(date: .omitted, time: .standard)) · \(recent[index].detail)")
            }
        }
    }
}

private struct WitnessMonitorDetailSheet: View {
    @EnvironmentObject private var model: WitnessAppModel
    @Environment(\.dismiss) private var dismiss
    let target: MonitorTarget
    @State private var editing = false
    @State private var confirmingRemoval = false
    @State private var checking = false
    @State private var error: String?
    @State private var availability: [(label: String, summary: UptimeSummary)] = []
    @State private var incidents: [AlertIncident] = []

    var body: some View {
        let state = model.monitorStates[target.id]
        VStack(alignment: .leading, spacing: 20) {
          ScrollView {
           VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 14) {
                WitnessMonitorTargetIcon(target: target, size: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text(target.name).font(.title2.weight(.semibold))
                    Text(target.address).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                WitnessStatusBadge(text: model.monitorStatusText(target), health: model.monitorHealth(target))
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 18, verticalSpacing: 10) {
                fact("Last check", state?.last.map { $0.time.formatted(date: .omitted, time: .standard) + " · " + $0.detail } ?? "Not checked yet")
                fact("Response time", state?.last?.latencyMilliseconds.map { "\($0) ms" } ?? "—")
                fact("Uptime", state?.uptime.map { "\(Int(($0 * 100).rounded()))% of last \(state?.history.count ?? 0) checks" } ?? "—")
                fact("Checks", "Every \(Self.duration(target.intervalSeconds)), \(target.timeoutSeconds) s timeout")
                fact("Reported down after", "\(target.failureThreshold) failed \(target.failureThreshold == 1 ? "check" : "checks") in a row")
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Recent checks").font(.headline)
                WitnessMonitorHistoryBar(results: state?.history ?? [], count: 60).frame(height: 28)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Status changes").font(.headline)
                if let changes = state?.changes, !changes.isEmpty {
                    ForEach(Array(changes.suffix(5).reversed()), id: \.time) { change in
                        HStack {
                            Image(systemName: change.status == .down ? "xmark.octagon.fill" : "checkmark.circle.fill")
                                .foregroundStyle(change.status == .down ? Color.red : Color.green).accessibilityHidden(true)
                            Text(change.status == .down ? "Went down" : change == changes.first && changes.count < MonitorState.changeLimit ? "First seen up" : "Came back up")
                                .font(.callout.weight(.medium))
                            Text(change.detail).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                            Spacer()
                            Text(change.time, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                } else {
                    Text("No changes since Ruru started watching.").font(.callout).foregroundStyle(.secondary)
                }
            }
            availabilitySection
            incidentsSection
            if let error { ConsoleIssue(title: "Could not complete that", detail: error) }
           }
          }
          .frame(maxHeight: 520)
            HStack {
                Button("Remove…", role: .destructive) { confirmingRemoval = true }
                Spacer()
                Button(checking ? "Checking…" : "Check Now") {
                    checking = true
                    Task { await model.checkMonitorNow(target.id); checking = false }
                }.disabled(checking || !target.enabled)
                Button("Edit…") { editing = true }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(24).frame(width: 560)
        .task(id: target.id) {
            // Durable history from the alert store; refreshed while the sheet is open.
            while !Task.isCancelled {
                availability = await model.monitorUptime(target.id)
                incidents = await model.alertIncidents(subjectKey: "monitoring|monitor|\(target.id)")
                try? await Task.sleep(for: .seconds(15))
            }
        }
        .sheet(isPresented: $editing) { WitnessMonitorTargetSheet(target: target).environmentObject(model) }
        .confirmationDialog("Remove \(target.name)?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button("Remove Target", role: .destructive) {
                Task {
                    do { try await model.removeMonitorTarget(id: target.id); dismiss() }
                    catch { self.error = error.localizedDescription }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Ruru stops checking it, discards its availability history, and archives any open incident. Nothing else is affected.")
        }
    }

    @ViewBuilder private var availabilitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Availability").font(.headline)
            if availability.allSatisfy({ $0.summary.checks == 0 }) {
                Text(model.alertSnapshot.storage.isUsable
                     ? "Ruru is collecting history. Availability over 24 hours, 7 and 30 days appears here."
                     : "Availability history isn't available right now.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 18, verticalSpacing: 6) {
                    ForEach(availability, id: \.label) { window in
                        GridRow {
                            Text("Last \(window.label)").font(.callout).foregroundStyle(.secondary).gridColumnAlignment(.leading)
                            Text(window.summary.ratio.map { Self.percent($0) } ?? "—").font(.callout.weight(.medium)).monospacedDigit()
                            Text(window.summary.checks == 0 ? "" : "\(window.summary.checks) checks"
                                 + (window.summary.averageLatencyMilliseconds.map { " · avg \($0) ms" } ?? "")
                                 + (window.summary.inconclusive > 0 ? " · \(window.summary.inconclusive) inconclusive" : ""))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Text("Checks that couldn't run, such as when this Mac was offline or asleep, aren't counted against availability.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var incidentsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Incidents").font(.headline)
            if incidents.isEmpty {
                Text("No incidents recorded. They appear here when an alert rule opens one.").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(incidents.prefix(6)) { incident in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: incident.isOpen ? (incident.verification == .unverified ? "questionmark.circle.fill" : "exclamationmark.circle.fill")
                              : (incident.resolution?.isRecovery == true ? "checkmark.circle.fill" : "archivebox.fill"))
                            .foregroundStyle(incident.isOpen ? (incident.verification == .unverified ? Color.orange : Color.red)
                                             : (incident.resolution?.isRecovery == true ? Color.green : Color.secondary))
                            .frame(width: 18).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(incident.isOpen ? (incident.verification == .unverified ? "Open — unverified since restart" : "Open")
                                 : (incident.resolution?.title ?? "Closed")).font(.callout.weight(.medium))
                            Text("\(incident.openedAt.formatted(date: .abbreviated, time: .shortened))" + (incident.resolvedAt.map {
                                " · lasted " + Threshold.durationText(max(1, Int($0.timeIntervalSince(incident.openedAt)))) } ?? ""))
                                .font(.caption).foregroundStyle(.secondary)
                            if incident.flapCount > 0 { Text("Changed state \(incident.flapCount + 1) times").font(.caption).foregroundStyle(.orange) }
                        }
                    }
                }
            }
        }
    }

    private static func percent(_ ratio: Double) -> String {
        let value = ratio * 100
        return value >= 99.995 ? "100%" : String(format: value >= 99 ? "%.2f%%" : "%.1f%%", value)
    }

    private func fact(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).font(.callout).foregroundStyle(.secondary).gridColumnAlignment(.leading)
            Text(value).font(.callout).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    static func duration(_ seconds: Int) -> String {
        seconds < 60 ? "\(seconds) s" : seconds == 60 ? "minute" : seconds % 60 == 0 ? "\(seconds / 60) minutes" : "\(seconds) s"
    }
}

/// Add or edit one target.
struct WitnessMonitorTargetSheet: View {
    @EnvironmentObject private var model: WitnessAppModel
    @Environment(\.dismiss) private var dismiss
    private let existing: MonitorTarget?
    private let targetID: String
    /// nil until the icon is edited; then `.some(nil)` means "use the default".
    @State private var editedIcon: Data??
    @State private var iconError: String?
    @State private var name: String
    @State private var kind: MonitorTarget.Kind
    @State private var host: String
    @State private var port: Int
    @State private var url: String
    @State private var interval: Int
    @State private var timeout: Int
    @State private var threshold: Int
    @State private var enabled: Bool
    @State private var saving = false
    @State private var error: String?

    private static let intervals = [30, 60, 120, 300, 600, 1800, 3600]
    private static let timeouts = [5, 10, 15, 20]

    init(target: MonitorTarget?) {
        existing = target
        targetID = target?.id ?? UUID().uuidString.lowercased()
        _name = State(initialValue: target?.name ?? "")
        _kind = State(initialValue: target?.kind ?? .tcp)
        _host = State(initialValue: target?.host ?? "")
        _port = State(initialValue: target?.port ?? 22)
        _url = State(initialValue: target?.url ?? "https://")
        _interval = State(initialValue: target?.intervalSeconds ?? MonitorTarget.defaultInterval)
        _timeout = State(initialValue: target?.timeoutSeconds ?? MonitorTarget.defaultTimeout)
        _threshold = State(initialValue: target?.failureThreshold ?? MonitorTarget.defaultThreshold)
        _enabled = State(initialValue: target?.enabled ?? true)
    }

    private var draft: MonitorTarget {
        MonitorTarget(id: targetID,
                      name: name.trimmingCharacters(in: .whitespacesAndNewlines), kind: kind,
                      host: host.trimmingCharacters(in: .whitespacesAndNewlines), port: port,
                      url: url.trimmingCharacters(in: .whitespacesAndNewlines),
                      intervalSeconds: interval, timeoutSeconds: timeout, failureThreshold: threshold, enabled: enabled)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            WitnessSheetHeader(title: existing == nil ? "Add Target" : "Edit Target",
                               subtitle: "Ruru checks this on a schedule and tells you when it stops answering.",
                               symbol: "waveform.path.ecg")
            VStack(alignment: .leading, spacing: 16) {
                WitnessServiceIconPicker(image: displayedIcon, templateSymbol: draft.symbol,
                                         onPick: pickIcon, onClear: { editedIcon = .some(nil) }, onError: { iconError = $0 })
                if let iconError { ConsoleIssue(title: "Icon could not be used", detail: iconError) }
                LabeledContent("Name") { TextField("Name", text: $name, prompt: Text("e.g. Home NAS or Company website")).labelsHidden() }
                Picker("Check type", selection: $kind) {
                    Text("TCP port").tag(MonitorTarget.Kind.tcp)
                    Text("HTTP(S) address").tag(MonitorTarget.Kind.http)
                }
                switch kind {
                case .tcp:
                    LabeledContent("Host") { TextField("Host", text: $host, prompt: Text("IP address or name, e.g. 192.168.1.20")).labelsHidden() }
                    LabeledContent("Port") { TextField("Port", value: $port, format: .number.grouping(.never)).labelsHidden().frame(width: 100) }
                    Text("Counts as up when a connection to this port opens.").font(.callout).foregroundStyle(.secondary)
                case .http:
                    LabeledContent("Address") { TextField("Address", text: $url, prompt: Text("https://example.com/health")).labelsHidden() }
                    Text("Counts as up when the server answers with a status below 400. Redirects are not followed.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Picker("Check every", selection: $interval) {
                    ForEach(Self.intervals.contains(interval) ? Self.intervals : (Self.intervals + [interval]).sorted(), id: \.self) {
                        Text($0 < 60 ? "\($0) seconds" : $0 == 60 ? "1 minute" : "\($0 / 60) minutes").tag($0)
                    }
                }
                Picker("Give up after", selection: $timeout) {
                    ForEach(Self.timeouts.contains(timeout) ? Self.timeouts : (Self.timeouts + [timeout]).sorted(), id: \.self) { Text("\($0) seconds").tag($0) }
                }
                Picker("Report down after", selection: $threshold) {
                    ForEach(1...5, id: \.self) { Text($0 == 1 ? "1 failed check" : "\($0) failed checks").tag($0) }
                }
                Toggle("Check this target", isOn: $enabled)
                if let error { ConsoleIssue(title: "Target could not be saved", detail: error) }
            }.textFieldStyle(.roundedBorder)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Spacer()
                Button(saving ? "Saving…" : "Save") {
                    saving = true
                    Task {
                        do {
                            try await model.saveMonitorTarget(draft)
                            if let editedIcon { model.setServiceIcon(editedIcon, for: targetID) }
                            dismiss()
                        }
                        catch { self.error = error.localizedDescription; saving = false }
                    }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!draft.isValid || saving)
            }
        }.padding(24).frame(width: 560).interactiveDismissDisabled(saving)
            .serviceIconDrop(onPick: pickIcon, onError: { iconError = $0 })
    }

    private var displayedIcon: NSImage? {
        guard let editedIcon else { return model.serviceIcons[targetID] }
        return editedIcon.flatMap { NSImage(data: $0) }
    }

    private func pickIcon(_ pick: RuruServiceIcons.Pick) {
        editedIcon = .some(pick.png)
        iconError = nil
        // Dropping an app fills in its name unless one has been typed already.
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let suggested = pick.suggestedName { name = suggested }
    }
}
