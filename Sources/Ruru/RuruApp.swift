import AppKit
import SwiftUI

@main
struct RuruApp: App {
    @NSApplicationDelegateAdaptor(WitnessAppDelegate.self) private var delegate
    @StateObject private var model = WitnessAppModel()
    @StateObject private var updater = AppUpdater()

    var body: some Scene {
        Window("Ruru", id: "witness") {
            WitnessWindowContent(delegate: delegate).environmentObject(model).environmentObject(updater)
        }
        .defaultSize(width: 1180, height: 850)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
        }
        MenuBarExtra("Ruru", systemImage: "checkmark.shield") {
            WitnessMenu().environmentObject(model).environmentObject(updater).onAppear {
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
    @Environment(\.openWindow) private var openWindow

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
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
        Button("Quit Ruru") { NSApplication.shared.terminate(nil) }
    }
}
