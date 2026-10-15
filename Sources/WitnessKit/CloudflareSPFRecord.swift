import Foundation

/// A deliberately conservative SPF editor for provider setup. Ruru must never
/// replace a domain's existing SPF record: other senders may rely on it.
public enum CloudflareSPFRecord {
    public enum Error: LocalizedError, Equatable, Sendable {
        case invalidRecord, invalidInclude, recordTooLong

        public var errorDescription: String? {
            switch self {
            case .invalidRecord: "The existing TXT value is not a single valid-looking SPF record."
            case .invalidInclude: "The requested SPF include is invalid."
            case .recordTooLong: "Adding this sender would make the SPF record too long; review it manually."
            }
        }
    }

    /// Adds an `include:` mechanism immediately before `all` or `redirect=`.
    /// No other mechanisms, qualifiers, ordering or policy are changed. A
    /// duplicate include is a no-op. This intentionally does not attempt to
    /// calculate the DNS lookup budget: that needs provider-side resolution.
    public static func addingInclude(_ include: String, to record: String) throws -> String {
        let requested = include.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard requested.hasPrefix("include:"), requested.utf8.count > "include:".utf8.count,
              requested.utf8.count <= 253, !requested.contains(where: { $0.isWhitespace || $0.isNewline }),
              !requested.contains("\"") else {
            throw Error.invalidInclude
        }
        let fields = record.split(whereSeparator: { $0.isWhitespace })
        guard fields.count >= 1, fields.first?.lowercased() == "v=spf1",
              !record.contains(where: { $0.isNewline || $0 == "\0" }) else { throw Error.invalidRecord }
        var terms = fields.map(String.init)
        if terms.dropFirst().contains(where: { $0.lowercased() == requested }) { return terms.joined(separator: " ") }
        let insertion = terms.firstIndex { term in
            let normalized = term.lowercased().drop(while: { "+-~?".contains($0) })
            return normalized == "all" || normalized.hasPrefix("redirect=")
        } ?? terms.endIndex
        terms.insert(requested, at: insertion)
        let result = terms.joined(separator: " ")
        // Cloudflare accepts quoted chunks, but automated chunking can obscure
        // a review. Ask the operator to resolve a complex record instead.
        guard result.utf8.count <= 255 else { throw Error.recordTooLong }
        return result
    }
}
