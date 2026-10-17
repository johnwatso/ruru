import Foundation

/// Separates a service's current servers from earlier identities. A reinstall or reset
/// mints a new node ID, leaving the old one only in ownership history under the same name.
public enum KnownNodeGrouping {
    public static func group(nodes: [String], names: [String: String], live: Set<String>,
                             pinned: Set<String>) -> (current: [String], earlier: [String]) {
        let liveNames = Set(nodes.filter(live.contains).compactMap { names[$0] })
        let earlier = nodes.filter { node in
            !live.contains(node) && !pinned.contains(node) && names[node].map(liveNames.contains) == true
        }
        return (nodes.filter { !earlier.contains($0) }, earlier)
    }
}
