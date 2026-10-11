import AppKit
import SwiftUI

@main
struct RuruApp: App {
    @NSApplicationDelegateAdaptor(WitnessAppDelegate.self) private var delegate
    @StateObject private var model = WitnessAppModel()
    @StateObject private var updater = AppUpdater()
    @StateObject private var diagnostics = RuruDiagnosticExportSession()

    var body: some Scene {
        Window("Ruru", id: "witness") {
            WitnessWindowContent(delegate: delegate).environmentObject(model).environmentObject(updater).environmentObject(diagnostics)
                .ruruDiagnosticExportPresenter(diagnostics)
        }
        .defaultSize(width: 1180, height: 850)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(replacing: .appInfo) {
                Button("About Ruru") { RuruAboutPanel.show() }
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
        }
        Settings {
            WitnessSettingsView(configuration: model.configuration)
                .environmentObject(model).environmentObject(updater).environmentObject(diagnostics)
        }
        .windowResizability(.contentSize)
        MenuBarExtra("Ruru", systemImage: model.menuBarSymbol) {
            WitnessMenu().environmentObject(model).environmentObject(updater).environmentObject(diagnostics).onAppear {
                delegate.model = model
                updater.prepareForInstallation = model.shutdown
                updater.start()
            }
        }
    }
}

@MainActor
final class WitnessAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: WitnessAppModel?
    var openMainWindow: (() -> Void)?

    private var terminating = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating, let model else { return .terminateNow }
        terminating = true
        Task {
            await model.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openMainWindow?() }
        return true
    }
}

private struct WitnessWindowContent: View {
    @EnvironmentObject private var model: WitnessAppModel
    @EnvironmentObject private var updater: AppUpdater
    @Environment(\.openWindow) private var openWindow
    let delegate: WitnessAppDelegate

    var body: some View {
        WitnessDashboard().onAppear {
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("--preview-screenshots") {
                if arguments.contains("--preview-dark") {
                    NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
                } else if arguments.contains("--preview-light") {
                    NSApplication.shared.appearance = NSAppearance(named: .aqua)
                }
                if arguments.contains("--preview-light") || arguments.contains("--preview-dark") {
                    Task { @MainActor in
                        if let window = NSApplication.shared.windows.first(where: { $0.title == "Ruru" && $0.canBecomeMain }) {
                            let frame = window.frame
                            window.setFrame(NSRect(x: frame.minX, y: frame.maxY - 850,
                                                   width: 1305, height: 850), display: true)
                        }
                    }
                }
            }
            delegate.model = model
            delegate.openMainWindow = { openWindow(id: "witness") }
            model.applyDockVisibility()
            updater.prepareForInstallation = model.shutdown
            updater.start()
        }
    }
}

private struct WitnessMenu: View {
    @EnvironmentObject private var model: WitnessAppModel
    @EnvironmentObject private var updater: AppUpdater
    @EnvironmentObject private var diagnostics: RuruDiagnosticExportSession
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text("Ruru: \(model.statusText)")
        Text("Guarding " + model.guardingSummary).font(.caption)
        Divider()
        Button("Open Ruru…") {
            openWindow(id: "witness")
            NSApplication.shared.activate()
        }
        Button(model.state == .running ? "Stop Service" : "Start Service") {
            Task {
                if model.state == .running { await model.stop() }
                else { await model.start() }
            }
        }.disabled(model.busy || model.internetBusy)
        Divider()
        // Without a Dock icon there is no app menu, so About lives here too.
        Button("About Ruru") { RuruAboutPanel.show() }
        Button("Settings…") {
            NSApplication.shared.activate()
            openSettings()
        }
        Button(diagnostics.isPreparing ? "Preparing Diagnostic Report…" : "Export Diagnostic Report…") {
            openWindow(id: "witness")
            NSApplication.shared.activate()
            diagnostics.begin(model: model)
        }.disabled(diagnostics.isPreparing || diagnostics.isExporterPresented)
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
        Button("Quit Ruru") { NSApplication.shared.terminate(nil) }
    }
}

/// The standard About panel, with a link to release notes in its credits.
@MainActor
enum RuruAboutPanel {
    static func show() {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let credits = NSAttributedString(string: "Release Notes", attributes: [
            .link: URL(string: "https://github.com/johnwatso/ruru/releases")!,
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .paragraphStyle: style
        ])
        NSApplication.shared.activate()
        NSApplication.shared.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
}
