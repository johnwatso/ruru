#if canImport(Sparkle)
import AppKit
import Foundation
import Sparkle

/// SwiftMiner's standard-driver wording adaptation. Development builds can have
/// the same marketing version and a newer build than the latest release. Keep
/// that result readable while preserving unsupported-OS/hardware explanations.
final class UpToDateUserDriver: SPUStandardUserDriver {

    override func showUpdateNotFoundWithError(
        _ error: any Error,
        acknowledgement: @escaping () -> Void
    ) {
        let nsError = error as NSError

        guard let suggestion = Self.plainRecoverySuggestion(for: nsError) else {
            super.showUpdateNotFoundWithError(error, acknowledgement: acknowledgement)
            return
        }

        var userInfo = nsError.userInfo
        userInfo[NSLocalizedRecoverySuggestionErrorKey] = suggestion

        super.showUpdateNotFoundWithError(
            NSError(domain: nsError.domain, code: nsError.code, userInfo: userInfo),
            acknowledgement: acknowledgement
        )
    }

    /// The single "you are on the newest version" sentence, or `nil` when
    /// Sparkle's own wording should stand.
    static func plainRecoverySuggestion(for error: NSError, bundle: Bundle = .main) -> String? {
        guard let rawReason = error.userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber,
              let reason = SPUNoUpdateFoundReason(rawValue: OSStatus(rawReason.intValue)) else {
            return nil
        }

        switch reason {
        case .unknown, .onLatestVersion, .onNewerThanLatestVersion:
            break
        case .systemIsTooOld, .systemIsTooNew, .hardwareDoesNotSupportARM64:
            return nil
        @unknown default:
            return nil
        }

        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "Ruru"
        let version = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !version.isEmpty else { return nil }

        return "\(name) \(version) is currently the newest version available."
    }
}
#endif
