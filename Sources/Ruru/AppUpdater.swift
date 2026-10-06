import Combine
import Sparkle
import SwiftUI

/// Local adaptation of SwiftMiner's Sparkle integration. Sparkle owns scheduling
/// and its persisted preferences; authority shutdown stays with the app delegate.
@MainActor
final class AppUpdater: NSObject, ObservableObject {
    typealias UpdateChannel = RuruUpdateConfiguration.Channel
    private static let channelDefaultsKey = "RuruAppUpdateChannel"
    @Published private(set) var selectedChannel: UpdateChannel = .stable
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var automaticallyDownloadsUpdates = false
    @Published private(set) var lastCheckDate: Date?
    @Published private(set) var error: String?
    let isPreview: Bool
    let isConfigured: Bool
    private let configuration: RuruUpdateConfiguration?
    private let hostBundle: Bundle
    private let defaults: UserDefaults
    private var sparkleUpdater: SPUUpdater?
    private var userDriver: UpToDateUserDriver?
    var prepareForInstallation: (() async -> Void)?

    init(bundle: Bundle = .main, defaults: UserDefaults = .standard,
         preview: Bool = ProcessInfo.processInfo.arguments.contains("--preview")) {
        isPreview = preview
        self.defaults = defaults
        hostBundle = bundle
        configuration = RuruUpdateConfiguration(info: bundle.infoDictionary ?? [:])
        isConfigured = configuration != nil
        super.init()
        guard !preview else { return }
        selectedChannel = UpdateChannel(rawValue: defaults.string(forKey: Self.channelDefaultsKey) ?? "") ?? .stable
    }

    /// Start only once application launch is complete, independently of windows.
    func start() {
        guard !isPreview, isConfigured, sparkleUpdater == nil else { return }
        let driver = UpToDateUserDriver(hostBundle: hostBundle, delegate: nil)
        let updater = SPUUpdater(hostBundle: hostBundle, applicationBundle: hostBundle,
                                 userDriver: driver, delegate: self)
        userDriver = driver
        sparkleUpdater = updater
        do {
            try updater.start()
            updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
            updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticallyChecksForUpdates)
            updater.publisher(for: \.automaticallyDownloadsUpdates).assign(to: &$automaticallyDownloadsUpdates)
            updater.publisher(for: \.lastUpdateCheckDate).assign(to: &$lastCheckDate)
        } catch {
            self.error = error.localizedDescription
            sparkleUpdater = nil
            userDriver = nil
        }
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        error = nil
        sparkleUpdater?.checkForUpdates()
    }

    func apply(channel: UpdateChannel, automaticChecks: Bool, automaticDownloads: Bool) {
        guard !isPreview, let updater = sparkleUpdater else { return }
        if selectedChannel != channel {
            selectedChannel = channel
            defaults.set(channel.rawValue, forKey: Self.channelDefaultsKey)
            updater.resetUpdateCycleAfterShortDelay()
        }
        updater.automaticallyChecksForUpdates = automaticChecks
        updater.automaticallyDownloadsUpdates = automaticDownloads
    }
}

extension AppUpdater: SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        configuration?.feedURL(for: selectedChannel).absoluteString
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        selectedChannel == .beta ? ["beta"] : []
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard let prepareForInstallation else { return false }
        Task { @MainActor in
            await prepareForInstallation()
            installHandler()
        }
        return true
    }

    // Keep Sparkle's normal install-on-quit behavior. Do not force a background
    // restart while Ruru is granting leases. NSApplication termination calls
    // WitnessAppDelegate, which awaits listener/connector shutdown before exit.
}
