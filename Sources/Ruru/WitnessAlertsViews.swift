import AppKit
import RuruAlerting
import SwiftUI
import WitnessKit

// MARK: Model helpers

extension AlertRule {
    var symbol: String { descriptor?.symbol ?? "bell" }
}

extension AlertSeverity {
    var tint: Color {
        switch self {
        case .info: .secondary
        case .warning: .orange
        case .critical: .red
        }
    }
}

@MainActor
extension WitnessAppModel {
    /// What a rule can be limited to. nil means the trigger is about Ruru itself.
    func alertTargetOptions(for descriptor: TriggerDescriptor) -> [(id: String, name: String)]? {
        switch descriptor.subjectNoun {
        case "monitor": configuration.monitorTargets.map { ($0.id, $0.name) }
        case "service", "server": configuration.services.map { ($0.id, $0.name) }
        default: nil
        }
    }

    func alertTargetText(_ rule: AlertRule) -> String {
        guard let descriptor = rule.descriptor else { return "Unavailable trigger" }
        guard let options = alertTargetOptions(for: descriptor) else { return "Ruru" }
        let noun = descriptor.subjectNoun == "server" ? "servers" : descriptor.subjectNoun + "s"
        if rule.scope.isAll { return "All \(noun)" }
        let names = options.filter { rule.scope.ids.contains($0.id) }.map(\.name)
        switch names.count {
        case 0: return "No matching \(noun)"
        case 1: return names[0]
        default: return "\(names.count) \(noun)"
        }
    }

    func alertRuleSummary(_ rule: AlertRule) -> String {
        guard let descriptor = rule.descriptor else { return "Unavailable in this version" }
        var parts = [alertTargetText(rule)]
        if let spec = descriptor.limit, let limit = rule.limit { parts.append("over \(limit) \(spec.unit)") }
        if descriptor.supportsThreshold, rule.threshold != descriptor.defaultThreshold || rule.threshold.kind != .immediately {
            parts.append(rule.threshold.label.replacingOccurrences(of: "failed", with: descriptor.checkAdjective).lowercasedFirst)
        }
        return parts.joined(separator: " · ")
    }

    func openIncidents(for rule: AlertRule) -> [AlertIncident] {
        alertSnapshot.openIncidents.filter { $0.ruleID == rule.id }
    }
}

private extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}

private let durationPresets = [5, 15, 30, 60, 120, 300, 600, 900, 1_800, 3_600]
private let cooldownPresets = [0, 60, 300, 900, 1_800, 3_600, 21_600, 86_400]
private let repeatPresets = [300, 900, 1_800, 3_600, 21_600, 86_400]

// MARK: Page

struct WitnessAlertsPage: View {
    enum Mode: String, CaseIterable, Identifiable { case rules = "Rules", history = "History"; var id: Self { self } }

    @EnvironmentObject private var model: WitnessAppModel
    @State private var mode: Mode = .rules
    @State private var selectedID: UUID?
    @State private var search = ""
    @State private var inspectorShown = true
    @State private var inspectorPopover = false
    @State private var error: String?

    private var snapshot: AlertSnapshot { model.alertSnapshot }
    private var filteredRules: [AlertRule] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return snapshot.rules }
        return snapshot.rules.filter {
            $0.name.lowercased().contains(query) || ($0.descriptor?.title.lowercased().contains(query) ?? false)
                || model.alertRuleSummary($0).lowercased().contains(query)
        }
    }
    private var selectedRule: AlertRule? { snapshot.rules.first { $0.id == selectedID } }

    var body: some View {
        GeometryReader { proxy in
            let inline = proxy.size.width >= 1_080
            VStack(alignment: .leading, spacing: 18) {
                ConsolePageHeader(title: "Alerts", subtitle: subtitle) { headerAccessory }
                banners
                switch mode {
                case .rules: rulesLayout(inline: inline)
                case .history: WitnessAlertHistoryView()
                }
            }
            .padding(.horizontal, 36).padding(.top, 32).padding(.bottom, 28)
            .frame(maxWidth: 1_400, alignment: .topLeading).frame(maxWidth: .infinity)
        }
        .onAppear { if selectedID == nil { selectedID = snapshot.rules.first?.id } }
        .onChange(of: snapshot.rules.map(\.id)) { _, ids in
            if let selectedID, !ids.contains(selectedID) { self.selectedID = ids.first }
            else if selectedID == nil { selectedID = ids.first }
        }
        .alert("Couldn't complete that", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    private var subtitle: String {
        let open = snapshot.openIncidents.count
        let rules = snapshot.rules.count
        var text = "Decide what deserves a notification."
        if rules > 0 {
            text = "\(rules) \(rules == 1 ? "rule" : "rules")" + (open > 0 ? " · \(open) open \(open == 1 ? "incident" : "incidents")" : " · nothing needs attention")
        }
        return text
    }

    private var headerAccessory: some View {
        HStack(spacing: 12) {
            Picker("View", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().frame(width: 170)
            newRuleMenu
        }
    }

    private var newRuleMenu: some View {
        Menu {
            ForEach(AlertSource.allCases, id: \.self) { source in
                let templates = AlertTemplates.all.filter { $0.descriptor?.source == source }
                if !templates.isEmpty {
                    Section(source.title) {
                        ForEach(templates) { template in
                            Button { addFromTemplate(template.id) } label: {
                                Label(template.name, systemImage: template.descriptor?.symbol ?? "bell")
                            }
                        }
                    }
                }
            }
        } label: {
            Label("New Alert Rule", systemImage: "plus")
        } primaryAction: { addBlank() }
        .menuStyle(.borderedButton).buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
        .disabled(!model.alertRulesActive)
        .help("Create a blank rule, or choose a template from the menu")
    }

    @ViewBuilder private var banners: some View {
        VStack(spacing: 10) {
            if !model.alertRulesActive && snapshot.started {
                ConsoleIssue(title: "Alert rules are unavailable",
                             detail: "Ruru couldn't save rules, so it is using its earlier alert settings from Settings → Alerts. Check storage access and free space, then relaunch Ruru.",
                             health: .warning)
            }
            if let notice = snapshot.notice {
                ConsoleIssue(title: snapshot.storage.isUsable ? "Alerts recovered" : "Alert history is unavailable", detail: notice,
                             health: snapshot.storage.isUsable ? .warning : .error)
            }
            ForEach(AlertDestination.allCases.filter { snapshot.deliveryProblems[$0] != nil }, id: \.self) { destination in
                ConsoleIssue(title: "\(destination.title) didn't receive the last alert",
                             detail: snapshot.deliveryProblems[destination] ?? "", health: .warning)
            }
        }
    }

    // MARK: Rules layout

    @ViewBuilder private func rulesLayout(inline: Bool) -> some View {
        if snapshot.rules.isEmpty && snapshot.started {
            ConsoleSection("No alert rules yet") {
                ConsoleEmptyState(symbol: "bell.badge", title: "Nothing will notify you",
                                  detail: "Add a monitor or a guarded service and Ruru provides sensible default rules. You can also create one from a template.")
            }
        } else {
            HStack(alignment: .top, spacing: 14) {
                AlertRulesList(rules: filteredRules, selectedID: $selectedID, search: $search,
                               onToggle: toggle, onDuplicate: duplicate, onDelete: delete)
                    .frame(width: 250)
                Group {
                    if let rule = selectedRule {
                        AlertRuleEditor(rule: rule, onError: { error = $0 },
                                        inspectorToggle: inline ? $inspectorShown : nil,
                                        showInfo: inline ? nil : { inspectorPopover = true })
                            .id(rule.id)
                            .popover(isPresented: $inspectorPopover, arrowEdge: .bottom) {
                                AlertRuleInspector(rule: rule).frame(width: 320, height: 520).environmentObject(model)
                            }
                    } else {
                        ConsoleEmptyState(symbol: "bell", title: "Choose a rule", detail: "Select a rule to see and edit what triggers it.")
                            .consoleSurface()
                    }
                }.frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                if inline, inspectorShown, let rule = selectedRule {
                    AlertRuleInspector(rule: rule).frame(width: 300)
                }
            }.frame(maxHeight: .infinity)
        }
    }

    private func addBlank() {
        let trigger: TriggerID = model.configuration.monitorTargets.isEmpty ? .failoverCompleted : .monitorUnavailable
        let descriptor = TriggerCatalogue.descriptor(for: trigger)
        let rule = AlertRule(name: "New alert rule", trigger: trigger, severity: descriptor?.defaultSeverity)
        Task {
            do { selectedID = try await model.saveAlertRule(rule).id; mode = .rules }
            catch { self.error = error.localizedDescription }
        }
    }

    private func addFromTemplate(_ id: String) {
        Task {
            do { selectedID = try await model.addAlertRule(fromTemplate: id).id; mode = .rules }
            catch { self.error = error.localizedDescription }
        }
    }

    private func toggle(_ rule: AlertRule, _ enabled: Bool) {
        Task { do { try await model.setAlertRule(rule.id, enabled: enabled) } catch { self.error = error.localizedDescription } }
    }
    private func duplicate(_ rule: AlertRule) {
        Task {
            do { selectedID = try await model.duplicateAlertRule(rule.id).id }
            catch { self.error = error.localizedDescription }
        }
    }
    private func delete(_ rule: AlertRule) {
        Task { do { try await model.deleteAlertRule(rule.id) } catch { self.error = error.localizedDescription } }
    }
}

// MARK: Left — rules

private struct AlertRulesList: View {
    @EnvironmentObject private var model: WitnessAppModel
    let rules: [AlertRule]
    @Binding var selectedID: UUID?
    @Binding var search: String
    let onToggle: (AlertRule, Bool) -> Void
    let onDuplicate: (AlertRule) -> Void
    let onDelete: (AlertRule) -> Void
    @State private var confirmingDelete: AlertRule?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("Search rules", text: $search).textFieldStyle(.plain)
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(12)
            Divider()
            if rules.isEmpty {
                ConsoleEmptyState(symbol: "magnifyingglass", title: "No matches", detail: "No rule matches “\(search)”.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(rules) { rule in row(rule) }
                    }.padding(8)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .consoleSurface()
        .confirmationDialog("Delete “\(confirmingDelete?.name ?? "")”?", isPresented: Binding(
            get: { confirmingDelete != nil }, set: { if !$0 { confirmingDelete = nil } }), titleVisibility: .visible) {
            Button("Delete Rule", role: .destructive) { if let rule = confirmingDelete { onDelete(rule) } }
        } message: {
            Text("Any open incident for this rule is archived without a recovery notification. Default rules aren't added back.")
        }
    }

    private func row(_ rule: AlertRule) -> some View {
        let selected = rule.id == selectedID
        let open = model.openIncidents(for: rule)
        return HStack(spacing: 10) {
            ConsoleIconTile(symbol: rule.symbol, active: rule.enabled, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(rule.name).font(.callout.weight(.semibold)).lineLimit(1)
                    if !open.isEmpty {
                        Circle().fill(open.contains { $0.verification == .verified } ? Color.red : Color.orange)
                            .frame(width: 7, height: 7).accessibilityLabel("\(open.count) open")
                    }
                }
                Text(model.alertRuleSummary(rule)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Toggle("Enabled", isOn: Binding(get: { rule.enabled }, set: { onToggle(rule, $0) }))
                .labelsHidden().toggleStyle(.switch).controlSize(.mini)
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(selected ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { selectedID = rule.id }
        .contextMenu {
            Button(rule.enabled ? "Disable" : "Enable") { onToggle(rule, !rule.enabled) }
            Button("Duplicate") { onDuplicate(rule) }
            Divider()
            Button("Delete…", role: .destructive) { confirmingDelete = rule }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAction(named: "Select") { selectedID = rule.id }
    }
}

// MARK: Centre — editor

private struct AlertRuleEditor: View {
    @EnvironmentObject private var model: WitnessAppModel
    @Environment(\.openSettings) private var openSettings
    let rule: AlertRule
    let onError: (String) -> Void
    var inspectorToggle: Binding<Bool>?
    var showInfo: (() -> Void)?
    @State private var draft: AlertRule
    @State private var saving = false
    @State private var confirmingDelete = false
    @State private var advancedOpen = false

    init(rule: AlertRule, onError: @escaping (String) -> Void, inspectorToggle: Binding<Bool>?, showInfo: (() -> Void)?) {
        self.rule = rule; self.onError = onError; self.inspectorToggle = inspectorToggle; self.showInfo = showInfo
        _draft = State(initialValue: rule)
    }

    private var descriptor: TriggerDescriptor? { draft.descriptor }
    private var dirty: Bool { draft.normalized() != rule }
    private var problem: String? { draft.normalized().validationProblem }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Form {
                nameSection
                whenSection
                thenSection
                if descriptor?.supportsRecovery == true { recoverySection }
                advancedSection
            }
            .formStyle(.grouped).scrollContentBackground(.hidden)
            Divider()
            footer
        }
        .consoleSurface()
        .onChange(of: rule) { _, stored in
            // A change from outside the editor, such as the list's switch: adopt it
            // unless the user has unsaved edits.
            if !dirty { draft = stored } else { draft.enabled = stored.enabled }
        }
        .confirmationDialog("Delete “\(rule.name)”?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Rule", role: .destructive) {
                Task { do { try await model.deleteAlertRule(rule.id) } catch { onError(error.localizedDescription) } }
            }
        } message: { Text("Any open incident for this rule is archived without a recovery notification.") }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ConsoleIconTile(symbol: draft.symbol, active: draft.enabled, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text("Rule").font(.caption).foregroundStyle(.secondary)
                Text(rule.name).font(.headline).lineLimit(1)
            }
            Spacer()
            if let showInfo {
                Button { showInfo() } label: { Label("Rule Info", systemImage: "info.circle") }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).help("Status, history and notification preview")
            }
            if let inspectorToggle {
                Button { inspectorToggle.wrappedValue.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                    .help(inspectorToggle.wrappedValue ? "Hide the inspector" : "Show the inspector")
            }
        }.padding(.horizontal, 16).padding(.vertical, 12)
    }

    // MARK: Sections

    private var nameSection: some View {
        Section {
            TextField("Name", text: $draft.name, prompt: Text("Website unavailable"))
            Toggle("Enabled", isOn: $draft.enabled)
        }
    }

    private var sourceBinding: Binding<AlertSource> {
        Binding(get: { descriptor?.source ?? .monitoring }, set: { source in
            guard source != descriptor?.source, let first = TriggerCatalogue.triggers(for: source).first else { return }
            setTrigger(first.id)
        })
    }

    private var triggerBinding: Binding<TriggerID> {
        Binding(get: { draft.trigger }, set: { setTrigger($0) })
    }

    private func setTrigger(_ id: TriggerID) {
        guard let next = TriggerCatalogue.descriptor(for: id) else { return }
        let sameTargets = descriptor?.subjectNoun == next.subjectNoun
        draft.trigger = id
        draft.threshold = next.defaultThreshold
        draft.limit = next.limit?.defaultValue
        if !sameTargets { draft.scope = .all }
        if next.lifecycle == .event { draft.notifyOnRecovery = false; draft.repeatSeconds = nil }
        else if descriptor?.lifecycle == .event { draft.notifyOnRecovery = true }
        draft.severity = draft.severity == nil ? nil : draft.severity
    }

    private var whenSection: some View {
        Section {
            Picker("Source", selection: sourceBinding) {
                ForEach(AlertSource.allCases, id: \.self) { Label($0.title, systemImage: $0.symbol).tag($0) }
            }
            Picker("Trigger", selection: triggerBinding) {
                ForEach(TriggerCatalogue.triggers(for: descriptor?.source ?? .monitoring)) { Text($0.title).tag($0.id) }
                if descriptor == nil { Text("Unavailable").tag(draft.trigger) }
            }
            if let descriptor {
                Text(descriptor.summary).font(.callout).foregroundStyle(.secondary)
                targetRows(descriptor)
                if let spec = descriptor.limit { limitRow(spec) }
                if descriptor.supportsThreshold { thresholdRows(descriptor) }
                Label(descriptor.basis.label, systemImage: "scope").font(.callout).foregroundStyle(.secondary)
                    .help("What Ruru's knowledge about this condition is based on")
            }
        } header: { Text("When") }
    }

    @ViewBuilder private func targetRows(_ descriptor: TriggerDescriptor) -> some View {
        if let options = model.alertTargetOptions(for: descriptor) {
            let noun = descriptor.subjectNoun == "server" ? "servers" : descriptor.subjectNoun + "s"
            Picker("Applies to", selection: Binding(get: { draft.scope.isAll }, set: { all in
                if all { draft.scope = .all } else if draft.scope.isAll { draft.scope = AlertScope(ids: Set(options.prefix(1).map(\.id))) }
            })) {
                Text("All \(noun)").tag(true)
                Text("Selected \(noun)").tag(false)
            }
            if !draft.scope.isAll {
                if options.isEmpty {
                    Text(descriptor.subjectNoun == "monitor" ? "Add a monitor in Monitoring first." : "Add a service in Guarding first.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(options, id: \.id) { option in
                    Toggle(option.name, isOn: Binding(get: { draft.scope.ids.contains(option.id) }, set: { on in
                        if on { draft.scope.ids.insert(option.id) } else { draft.scope.ids.remove(option.id) }
                    })).padding(.leading, 12)
                }
            }
            if descriptor.subjectNoun == "server" {
                Text("Choose the services whose servers this rule watches.").font(.caption).foregroundStyle(.secondary)
            }
        } else {
            LabeledContent("Applies to", value: "Ruru")
        }
    }

    private func limitRow(_ spec: LimitSpec) -> some View {
        LabeledContent(spec.title) {
            HStack(spacing: 6) {
                TextField("", value: Binding(get: { draft.limit ?? spec.defaultValue }, set: { draft.limit = $0 }),
                          format: .number.grouping(.never))
                    .labelsHidden().multilineTextAlignment(.trailing).frame(width: 70).textFieldStyle(.roundedBorder)
                Text(spec.unit).foregroundStyle(.secondary)
                Stepper("", value: Binding(get: { draft.limit ?? spec.defaultValue }, set: { draft.limit = $0 }),
                        in: spec.range, step: spec.step).labelsHidden()
            }
        }
    }

    @ViewBuilder private func thresholdRows(_ descriptor: TriggerDescriptor) -> some View {
        Picker("Alert", selection: Binding(get: { draft.threshold.kind }, set: { kind in
            switch kind {
            case .immediately: draft.threshold = .immediately
            case .sourceDefault: draft.threshold = .sourceDefault
            case .afterSeconds: draft.threshold = .after(draft.threshold.kind == .afterSeconds ? draft.threshold.value : 60)
            case .failedChecks: draft.threshold = .failedChecks(draft.threshold.kind == .failedChecks ? draft.threshold.value : 3)
            }
        })) {
            ForEach(descriptor.thresholds, id: \.self) { Text($0.title.replacingOccurrences(of: "failed", with: descriptor.checkAdjective)).tag($0) }
        }
        if draft.threshold.kind == .afterSeconds {
            Picker("Duration", selection: Binding(get: { draft.threshold.value }, set: { draft.threshold = .after($0) })) {
                ForEach(Array(Set(durationPresets + [draft.threshold.value])).sorted(), id: \.self) {
                    Text(Threshold.durationText($0)).tag($0)
                }
            }
        }
        if draft.threshold.kind == .failedChecks {
            Stepper(value: Binding(get: { draft.threshold.value }, set: { draft.threshold = .failedChecks($0) }), in: 1...10) {
                Text("\(descriptor.checkAdjective.capitalized) checks in a row: \(draft.threshold.value)")
            }
        }
        if descriptor.limit != nil {
            Text("Only checks that succeed have a response time. A monitor that is down is handled by the unavailable rule.")
                .font(.caption).foregroundStyle(.secondary)
        } else if descriptor.source == .monitoring {
            Text("A check that can't run, such as when this Mac has no network, never counts as a failure.")
                .font(.caption).foregroundStyle(.secondary)
        } else if draft.threshold.kind == .afterSeconds {
            Text("The condition must still hold, with fresh evidence, when the time is up.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var thenSection: some View {
        Section {
            Picker("Send to", selection: Binding(get: { draft.delivery.useAllEnabled }, set: { draft.delivery.useAllEnabled = $0 })) {
                Text("All enabled destinations").tag(true)
                Text("Choose destinations").tag(false)
            }
            if draft.delivery.useAllEnabled {
                let enabled = model.enabledAlertDestinations
                Text(enabled.isEmpty ? "No destination is turned on in Settings, so this rule only records history."
                     : "Currently: " + AlertDestination.allCases.filter(enabled.contains).map(\.title).joined(separator: ", "))
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(AlertDestination.allCases, id: \.self) { destination in
                    Toggle(isOn: Binding(get: { draft.delivery.destinations.contains(destination) }, set: { on in
                        if on { draft.delivery.destinations.insert(destination) } else { draft.delivery.destinations.remove(destination) }
                    })) {
                        Text(destination.title)
                        if !model.enabledAlertDestinations.contains(destination) {
                            Text("Not set up, or turned off, in Settings").font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
            }
            Toggle("Record in Activity", isOn: $draft.recordActivity)
            Button("Manage Destinations in Settings…") { NSApplication.shared.activate(); openSettings() }
                .buttonStyle(.link)
        } header: { Text("Then") }
    }

    private var recoverySection: some View {
        Section {
            Toggle(isOn: $draft.notifyOnRecovery) {
                Text("Notify when the condition resolves")
                Text("One rule covers both: a single incident opens, and its recovery is announced only if the opening was.")
            }
        } header: { Text("Recovery") }
    }

    private var advancedSection: some View {
        Section {
            DisclosureGroup("Cooldown, repeats, quiet hours and severity", isExpanded: $advancedOpen) {
                Picker("Severity", selection: Binding(get: { draft.severity }, set: { draft.severity = $0 })) {
                    Text("Default (\(descriptor?.defaultSeverity.title ?? "Warning"))").tag(AlertSeverity?.none)
                    ForEach(AlertSeverity.allCases, id: \.self) { Text($0.title).tag(AlertSeverity?.some($0)) }
                }
                Picker("Cooldown", selection: $draft.cooldownSeconds) {
                    ForEach(Array(Set(cooldownPresets + [draft.cooldownSeconds])).sorted(), id: \.self) {
                        Text($0 == 0 ? "None" : Threshold.durationText($0)).tag($0)
                    }
                }
                Text("Minimum time between notifications for the same target. A recovery is still announced.")
                    .font(.caption).foregroundStyle(.secondary)
                if descriptor?.supportsRecovery == true {
                    Picker("Remind me while unresolved", selection: Binding(get: { draft.repeatSeconds }, set: { draft.repeatSeconds = $0 })) {
                        Text("Never").tag(Int?.none)
                        ForEach(Array(Set(repeatPresets + [draft.repeatSeconds].compactMap { $0 })).sorted(), id: \.self) {
                            Text("Every \(Threshold.durationText($0))").tag(Int?.some($0))
                        }
                    }
                }
                Toggle("Quiet hours", isOn: Binding(get: { draft.quietHours != nil }, set: { on in
                    draft.quietHours = on ? (draft.quietHours ?? QuietHours(startMinute: 22 * 60, endMinute: 7 * 60)) : nil
                }))
                if let quiet = draft.quietHours {
                    DatePicker("From", selection: minuteBinding(quiet.startMinute) { draft.quietHours?.startMinute = $0 },
                               displayedComponents: .hourAndMinute)
                    DatePicker("Until", selection: minuteBinding(quiet.endMinute) { draft.quietHours?.endMinute = $0 },
                               displayedComponents: .hourAndMinute)
                    Toggle("Still send critical alerts", isOn: Binding(get: { quiet.allowCritical }, set: { draft.quietHours?.allowCritical = $0 }))
                    Text("Notifications held back during quiet hours are sent afterwards if the problem is still open.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: { Text("Advanced") }
    }

    private func minuteBinding(_ minute: Int, set: @escaping (Int) -> Void) -> Binding<Date> {
        Binding(get: {
            Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: Date()) ?? Date()
        }, set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            set((parts.hour ?? 0) * 60 + (parts.minute ?? 0))
        })
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Delete…", role: .destructive) { confirmingDelete = true }
            if let problem, dirty {
                Label(problem, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange).lineLimit(2)
            }
            Spacer()
            Button("Revert") { draft = rule }.disabled(!dirty || saving)
            Button("Save") { save() }.buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction).disabled(!dirty || problem != nil || saving)
        }.padding(.horizontal, 16).padding(.vertical, 12)
    }

    private func save() {
        saving = true
        Task {
            defer { saving = false }
            do { draft = try await model.saveAlertRule(draft) } catch { onError(error.localizedDescription) }
        }
    }
}

// MARK: Right — inspector

struct AlertRuleInspector: View {
    @EnvironmentObject private var model: WitnessAppModel
    let rule: AlertRule

    private var open: [AlertIncident] { model.openIncidents(for: rule) }
    private var entries: [AlertHistoryEntry] { model.alertSnapshot.history.filter { $0.ruleID == rule.id }.prefix(6).map { $0 } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                statusCard
                recentCard
                previewCard
            }.padding(14)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .consoleSurface()
    }

    private var status: (text: String, health: WitnessHealth) {
        if !rule.enabled { return ("Disabled", .inactive) }
        if open.contains(where: { $0.verification == .verified }) { return ("Firing", .error) }
        if !open.isEmpty { return ("Unverified", .warning) }
        return ("Watching", .healthy)
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Status").font(.headline)
            WitnessStatusBadge(text: status.text, health: status.health)
            if !open.isEmpty {
                ForEach(open) { incident in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(incident.subject.name).font(.callout.weight(.medium))
                        Text(incident.verification == .unverified
                             ? "Ruru restarted and hasn't observed this since. It stays open until fresh checks show it has recovered."
                             : "Open since \(incident.openedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            LabeledContent("Last triggered") {
                if let last = model.alertSnapshot.lastTriggered[rule.id] {
                    Text(last, format: .relative(presentation: .named)).help(last.formatted(date: .abbreviated, time: .standard))
                } else { Text("Never").foregroundStyle(.secondary) }
            }.font(.callout)
            if let descriptor = rule.descriptor {
                LabeledContent("Evidence") { Text(descriptor.basis.label).multilineTextAlignment(.trailing) }.font(.callout)
            }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var recentCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent triggers").font(.headline)
            if entries.isEmpty {
                Text("Nothing yet. When this rule fires, it shows here.").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(entries) { entry in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: entry.kindSymbol).foregroundStyle(entry.tint).frame(width: 18).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.title).font(.callout).lineLimit(2)
                            Text("\(entry.kind.title) · \(entry.time.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Notification preview").font(.headline)
            if let descriptor = rule.descriptor {
                AlertPreviewBanner(title: descriptor.sampleTitle, message: descriptor.sampleDetail, severity: rule.effectiveSeverity(descriptor))
                if descriptor.supportsRecovery, rule.notifyOnRecovery {
                    AlertPreviewBanner(title: descriptor.sampleRecoveryTitle, message: "Resolved.", severity: nil)
                }
            } else {
                Text("This rule's trigger isn't available in this version of Ruru.").font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

private struct AlertPreviewBanner: View {
    let title: String
    let message: String
    let severity: AlertSeverity?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 30, height: 30).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Ruru").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Text("now").font(.caption).foregroundStyle(.tertiary)
                }
                Text(title).font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder((severity?.tint ?? .green).opacity(0.35), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

extension AlertHistoryEntry {
    var kindSymbol: String {
        switch kind {
        case .opened: "exclamationmark.circle.fill"
        case .recovered, .stable: "checkmark.circle.fill"
        case .event: "bolt.circle.fill"
        case .reminder: "bell.badge.fill"
        case .flapping: "arrow.triangle.2.circlepath"
        case .archived: "archivebox.fill"
        case .suppressed: "bell.slash.fill"
        }
    }
    var tint: Color {
        switch kind {
        case .recovered, .stable: .green
        case .archived, .suppressed: .secondary
        case .flapping: .orange
        default: severity.tint
        }
    }
    /// A plain-language account of what happened to the notification.
    var deliverySummary: String {
        if let suppressedReason { return "Held back: \(suppressedReason)" }
        if deliveries.isEmpty { return kind == .archived ? "Closed without recovery" : "Recorded only" }
        let failed = deliveries.filter { !$0.ok }
        if failed.isEmpty { return "Delivered to " + deliveries.map { $0.destination.title }.sorted().joined(separator: ", ") }
        return "Failed: " + failed.map { "\($0.destination.title)" + ($0.message.map { " (\($0))" } ?? "") }.joined(separator: ", ")
    }
}

// MARK: History

struct WitnessAlertHistoryView: View {
    @EnvironmentObject private var model: WitnessAppModel

    private var snapshot: AlertSnapshot { model.alertSnapshot }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ConsoleSection(title: "Open incidents", accessory: { Text(snapshot.openIncidents.isEmpty ? "None" : "\(snapshot.openIncidents.count)") }, content: {
                    if snapshot.openIncidents.isEmpty {
                        ConsoleEmptyState(symbol: "checkmark.seal", title: "Nothing is open",
                                          detail: "Incidents appear here while a condition lasts, and stay until fresh observations show it has recovered.")
                    } else {
                        VStack(spacing: 0) {
                            ForEach(snapshot.openIncidents) { incident in
                                incidentRow(incident)
                                if incident.id != snapshot.openIncidents.last?.id { Divider().padding(.leading, 48) }
                            }
                        }.consoleRowGroup()
                    }
                })
                ConsoleSection(title: "History", accessory: { Text("\(snapshot.history.count) recent") }, content: {
                    if snapshot.history.isEmpty {
                        ConsoleEmptyState(symbol: "clock.arrow.circlepath", title: "No alerts yet",
                                          detail: "When a rule fires, recovers or is held back, it is recorded here with what was delivered.")
                    } else {
                        VStack(spacing: 0) {
                            ForEach(snapshot.history) { entry in
                                historyRow(entry)
                                if entry.id != snapshot.history.last?.id { Divider().padding(.leading, 48) }
                            }
                        }.consoleRowGroup()
                    }
                })
                if !snapshot.storage.isUsable {
                    Label("Alert history isn't being saved, so this list is lost when Ruru quits.", systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }.padding(.bottom, 8)
        }
    }

    private func incidentRow(_ incident: AlertIncident) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: incident.verification == .unverified ? "questionmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.title3).foregroundStyle(incident.verification == .unverified ? Color.orange : incident.severity.tint)
                .frame(width: 24).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(incident.title).font(.callout.weight(.semibold))
                Text(incident.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("\(incident.ruleName) · \(incident.basis.label) · since \(incident.openedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.tertiary)
                if incident.verification == .unverified {
                    Text("Unverified: Ruru restarted and hasn't observed this since. It is not shown as healthy.")
                        .font(.caption).foregroundStyle(.orange)
                }
                if incident.flapping { Text("Flapping — individual notifications are paused.").font(.caption).foregroundStyle(.orange) }
            }
            Spacer(minLength: 8)
            WitnessStatusBadge(text: incident.verification == .unverified ? "Unverified" : "Open",
                               health: incident.verification == .unverified ? .warning : .error)
        }.padding(14).accessibilityElement(children: .combine)
    }

    private func historyRow(_ entry: AlertHistoryEntry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: entry.kindSymbol).font(.title3).foregroundStyle(entry.tint).frame(width: 24).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title).font(.callout.weight(.semibold))
                Text("\(entry.kind.title) · \(entry.ruleName) · \(entry.subjectName)").font(.caption).foregroundStyle(.secondary)
                Text(entry.deliverySummary).font(.caption)
                    .foregroundStyle(entry.deliveries.contains { !$0.ok } ? Color.orange : Color.secondary.opacity(0.8))
            }
            Spacer(minLength: 8)
            Text(entry.time, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                .help(entry.time.formatted(date: .abbreviated, time: .standard))
        }.padding(14).accessibilityElement(children: .combine)
    }
}
