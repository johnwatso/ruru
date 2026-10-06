import Foundation

struct RuruUpdateConfiguration {
    enum Channel: String, CaseIterable, Identifiable {
        case stable, beta
        var id: String { rawValue }
        var label: String { self == .stable ? "Stable" : "Beta" }
    }

    let stableFeedURL: URL
    let publicKey: String

    init?(info: [String: Any]) {
        guard let feed = info["SUFeedURL"] as? String,
              let url = URL(string: feed), url.scheme == "https",
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.lastPathComponent == "appcast.xml",
              let key = info["SUPublicEDKey"] as? String,
              Data(base64Encoded: key)?.count == 32 else { return nil }
        stableFeedURL = url
        publicKey = key
    }

    func feedURL(for channel: Channel) -> URL {
        if channel == .stable { return stableFeedURL }
        return stableFeedURL.deletingLastPathComponent()
            .appendingPathComponent("beta").appendingPathComponent("appcast.xml")
    }
}
