import SwiftUI
import WitnessKit

/// One row of the compact activity feed shared by Overview and service pages.
struct ActivityFeedItem: Identifiable {
    let id: String
    let time: Date
    let symbol: String
    let tint: Color
    let title: String
    let service: String
    let node: String
}

@MainActor
extension WitnessAppModel {
    /// Ownership changes and server reports merged newest first, optionally for one service.
    func activityFeed(clusterID: String? = nil, limit: Int) -> [ActivityFeedItem] {
        let ownership = (snapshot?.events ?? [])
            .filter { clusterID == nil || $0.clusterID == clusterID }
            .prefix(limit).map { event -> ActivityFeedItem in
                let acquired = event.action == "Acquired"
                return ActivityFeedItem(
                    id: "own-\(event.clusterID)-\(event.id)", time: event.time,
                    symbol: acquired ? "checkmark.shield" : "arrow.right.circle",
                    tint: acquired ? .accentColor : .secondary,
                    title: acquired ? "Ownership acquired" : "Ownership released",
                    service: serviceName(for: event.clusterID),
                    node: nodeDisplayName(for: event.nodeID, reportedName: event.nodeName, clusterID: event.clusterID))
            }
        let reports = participantActivity
            .filter { clusterID == nil || $0.clusterID == clusterID }
            .prefix(limit).map { event -> ActivityFeedItem in
                let kind = ParticipantActivityKind(rawValue: event.kind)
                let warn = kind == .lowBattery || kind == .onBattery
                return ActivityFeedItem(
                    id: "report-\(event.id)", time: event.time,
                    symbol: kind?.symbol ?? "bolt.circle", tint: warn ? .orange : .accentColor,
                    title: kind?.title ?? "Participant update",
                    service: serviceName(for: event.clusterID), node: event.nodeName)
            }
        // Monitoring is not tied to a service, so it only joins the global feed.
        let monitoring: [ActivityFeedItem] = clusterID != nil ? [] : configuration.monitorTargets.flatMap { target in
            (monitorStates[target.id]?.changes ?? []).compactMap { change -> ActivityFeedItem? in
                guard change.status != .unknown else { return nil }
                let down = change.status == .down
                return ActivityFeedItem(
                    id: "monitor-\(target.id)-\(change.time.timeIntervalSince1970)", time: change.time,
                    symbol: down ? "xmark.octagon" : "checkmark.circle", tint: down ? .red : .green,
                    title: down ? "\(target.name) went down" : "\(target.name) is back up",
                    service: "Monitoring", node: target.address)
            }
        }
        return Array((ownership + reports + monitoring).sorted { $0.time > $1.time }.prefix(limit))
    }
}

struct ActivityFeedList: View {
    let items: [ActivityFeedItem]
    /// Hide the service name when the list is already scoped to one service.
    var showsService = true

    var body: some View {
        VStack(spacing: 0) {
            ForEach(items) { item in
                HStack(spacing: 12) {
                    Image(systemName: item.symbol).font(.system(size: 14, weight: .medium))
                        .foregroundStyle(item.tint).frame(width: 28, height: 28)
                        .background(item.tint.opacity(0.12), in: Circle())
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title).font(.callout.weight(.medium))
                        Text(showsService ? "\(item.service) · \(item.node)" : item.node)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 12)
                    Text(item.time, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
                        .font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                        .help(item.time.formatted(date: .abbreviated, time: .standard))
                }
                .padding(.vertical, 8).accessibilityElement(children: .combine)
                if item.id != items.last?.id { Divider().padding(.leading, 40) }
            }
        }
    }
}
