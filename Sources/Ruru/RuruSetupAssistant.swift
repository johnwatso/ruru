import SwiftUI
import WitnessKit

/// First-run setup: get Ruru itself working before any servers are added —
/// a public address, staying running, and alerts. Each step reads real state,
/// so closing the assistant and coming back resumes where setup stands.
struct RuruSetupAssistant: View {
    enum Step: Int, CaseIterable {
        case welcome, address, running, ready
        var title: String {
            switch self {
            case .welcome: "Welcome"
            case .address: "Public Address"
            case .running: "Keep Ruru Running"
            case .ready: "Ready"
            }
        }
    }

    @EnvironmentObject private var model: WitnessAppModel
    @State private var step: Step = .welcome
    @State private var started = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                Group {
                    switch step {
                    case .welcome: RuruSetupWelcome()
                    case .address: RuruSetupAddress(onSkip: { advance() })
                    case .running: RuruSetupFinish()
                    case .ready: RuruSetupReady()
                    }
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(width: 640, height: 600)
        .background(WitnessGlassBackground())
        .interactiveDismissDisabled()
        .onAppear {
            guard !started else { return }
            started = true
            step = resumeStep
        }
    }

    /// The first step that still needs doing.
    private var resumeStep: Step {
        let configuration = model.configuration
        guard configuration.tunnel.isConfigured || configuration.setup.localOnly else {
            return model.hasSavedCloudflareToken ? .address : .welcome
        }
        return .running
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 44, height: 44).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Set Up Ruru").font(.title2.weight(.semibold))
                Text("Step \(step.rawValue + 1) of \(Step.allCases.count) · \(step.title)")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.self) { item in
                    Capsule()
                        .fill(item.rawValue <= step.rawValue ? Color.accentColor : Color.primary.opacity(0.15))
                        .frame(width: item == step ? 22 : 8, height: 8)
                }
            }
            .animation(.snappy, value: step)
            .accessibilityHidden(true)
        }
        .padding(.horizontal, 24).padding(.vertical, 18)
    }

    private var footer: some View {
        HStack {
            if step != .ready {
                Button("Finish Later") { model.showingSetup = false }
                    .help("Close the assistant. Overview shows what’s left.")
            }
            Spacer()
            if step != .welcome {
                Button("Back") { move(-1) }
            }
            if step == .ready {
                Button("Done") { finish(then: nil) }
                Button("Add Your First App") { finish(then: .guarding) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            } else {
                Button(continueTitle) { advance() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(!canContinue)
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 16)
    }

    private var canContinue: Bool {
        switch step {
        case .welcome, .running, .ready: true
        case .address: model.configuration.tunnel.isConfigured || model.configuration.setup.localOnly
        }
    }

    private var continueTitle: String {
        step == .welcome ? "Get Started" : "Continue"
    }

    private func finish(then page: WitnessPage?) {
        Task {
            try? await model.updateSetup { $0.completed = true }
            model.showingSetup = false
            if let page { model.selectedPage = page }
        }
    }

    private func advance() { move(1) }
    private func move(_ offset: Int) {
        guard let next = Step(rawValue: step.rawValue + offset) else { return }
        step = next
    }
}

// MARK: Steps

private struct RuruSetupWelcome: View {
    @EnvironmentObject private var model: WitnessAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Ruru makes sure only one of your servers acts at a time.")
                .font(.title3.weight(.semibold))
            Text("Apps like SwiftBot run on more than one Mac for failover. Ruru is the referee they all check with: one server owns the work, and if it stops, another takes over safely.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 14) {
                RuruSetupBullet(symbol: "globe", title: "A public address",
                                detail: "Your servers reach Ruru over HTTPS through a Cloudflare tunnel. You need a domain on Cloudflare and an API token; no port forwarding.")
                RuruSetupBullet(symbol: "bell", title: "Alerts",
                                detail: "Optional notifications or Discord messages when something needs your attention.")
                RuruSetupBullet(symbol: "powerplug", title: "This Mac stays on",
                                detail: "Run Ruru on a Mac that isn’t one of your servers, and keep it awake and online.")
            }
            Text("Setup gets Ruru itself working; you’ll add apps like SwiftBot and pair their servers afterwards. It takes a few minutes, and you can stop and continue later.")
                .font(.callout).foregroundStyle(.secondary)
            Divider()
            HStack(alignment: .firstTextBaseline) {
                Text("Only want to watch websites, Macs or network services?")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Skip Setup — Monitor Only") {
                    Task {
                        try? await model.updateSetup { $0.completed = true; $0.localOnly = true }
                        model.showingSetup = false
                        model.selectedPage = .monitoring
                    }
                }.buttonStyle(.link)
                    .help("Monitoring and alerts work without a public address or any guarded service.")
            }
        }
    }
}

private struct RuruSetupAddress: View {
    @EnvironmentObject private var model: WitnessAppModel
    let onSkip: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Give Ruru a public address").font(.title3.weight(.semibold))
            Text("Your servers reach Ruru over HTTPS through its own Cloudflare tunnel, from anywhere. Nothing needs to be opened on your router.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            RuruCloudflareConnect()
            if !model.configuration.tunnel.isConfigured {
                Divider()
                HStack {
                    Text(model.configuration.setup.localOnly
                         ? "Testing on this Mac only. Other Macs can’t reach Ruru until you add an address."
                         : "Only testing on this Mac?")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    if !model.configuration.setup.localOnly {
                        Button("Skip — Local Testing Only") {
                            Task { try? await model.updateSetup { $0.localOnly = true }; onSkip() }
                        }.buttonStyle(.link)
                    }
                }
            }
        }
    }
}

private struct RuruSetupFinish: View {
    @EnvironmentObject private var model: WitnessAppModel
    @State private var settingUpDiscord = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Keep Ruru running").font(.title3.weight(.semibold))
            Text("Ruru only protects your servers while it’s running. These make sure it comes back after a restart, and tells you when something goes wrong.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                Toggle(isOn: Binding(get: { model.launchAtLogin }, set: { value in Task { await model.setLaunchAtLogin(value) } })) {
                    Text("Open Ruru at login")
                    Text("macOS may ask you to approve it in System Settings → General → Login Items.")
                }
                Toggle(isOn: preference(\.startAutomatically)) {
                    Text("Start the service when Ruru opens")
                }
                Toggle(isOn: alertPreference(\.notifications)) {
                    Text("Notify me about problems")
                    Text("A service going down, a failover, or Ruru itself having trouble.")
                }
                LabeledContent {
                    Button(model.discordConfigured ? "Replace…" : "Set Up…") { settingUpDiscord = true }
                } label: {
                    Text("Discord alerts")
                    Text(model.discordConfigured ? "Posting to your webhook." : "Optional: post alerts to a Discord channel.")
                }
            }
            .formStyle(.grouped).scrollDisabled(true).fixedSize(horizontal: false, vertical: true)
            Text("Also set this Mac to not sleep automatically while plugged in (System Settings → Energy). Everything here can be changed later in Settings.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { model.refreshLoginStatus() }
        .sheet(isPresented: $settingUpDiscord) { WitnessDiscordSetupSheet().environmentObject(model) }
    }

    private func preference(_ keyPath: WritableKeyPath<WitnessConfiguration, Bool>) -> Binding<Bool> {
        Binding(get: { model.configuration[keyPath: keyPath] }, set: { value in
            var draft = model.configuration
            draft[keyPath: keyPath] = value
            Task { try? await model.saveConfiguration(draft) }
        })
    }

    private func alertPreference(_ keyPath: WritableKeyPath<RuruAlertPreferences, Bool>) -> Binding<Bool> {
        Binding(get: { model.configuration.alerts[keyPath: keyPath] }, set: { value in
            var draft = model.configuration
            draft.alerts[keyPath: keyPath] = value
            Task { try? await model.saveConfiguration(draft) }
        })
    }
}

private struct RuruSetupReady: View {
    @EnvironmentObject private var model: WitnessAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Ruru is ready").font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: 10) {
                check(model.state == .running, "Ruru’s service is running")
                if model.configuration.tunnel.isConfigured {
                    check(model.internetStatus.state == .enabled, "Reachable at \(model.configuration.publicEndpoint)")
                } else {
                    check(false, "No public address (local testing only)")
                }
                check(model.launchAtLogin, "Opens at login")
                check(model.configuration.alerts.notifications || model.discordConfigured, "Alerts are on")
            }
            Text("Next, add the app your servers run — SwiftBot or your own — then pair each server with a code. You’ll find everything under Guarding.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { model.refreshLoginStatus() }
    }

    private func check(_ done: Bool, _ text: String) -> some View {
        Label {
            Text(text).foregroundStyle(done ? .primary : .secondary)
        } icon: {
            Image(systemName: done ? "checkmark.circle.fill" : "minus.circle").foregroundStyle(done ? .green : .secondary)
        }
    }
}

private struct RuruSetupBullet: View {
    let symbol: String
    let title: String
    let detail: String
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ConsoleIconTile(symbol: symbol, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
