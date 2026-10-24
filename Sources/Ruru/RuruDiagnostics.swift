import Darwin
import Foundation

/// A deliberately small, redacted support report. It is assembled from the
/// app's existing bounded snapshots and does not read credentials, the lease
/// database, or a participant's files.
enum RuruDiagnostics {
    /// Read only our own process. No credentials, paths or other processes are inspected.
    struct Resources: Sendable, Codable {
        let residentBytes: UInt64?
        /// Includes compressed memory charged to Ruru, unlike resident size.
        let physicalFootprintBytes: UInt64?
        let processAgeSeconds: Double?

        static func capture() -> Self {
            var memory = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
            let status = withUnsafeMutablePointer(to: &memory) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            var process = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            let received = proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &process, size)
            let started = Double(process.pbi_start_tvsec) + Double(process.pbi_start_tvusec) / 1_000_000
            return Self(residentBytes: status == KERN_SUCCESS ? memory.resident_size : nil,
                        physicalFootprintBytes: status == KERN_SUCCESS ? memory.phys_footprint : nil,
                        processAgeSeconds: received == size ? max(0, Date().timeIntervalSince1970 - started) : nil)
        }
    }

    struct Snapshot: Sendable {
        struct Lease: Sendable {
            let owner: String?
            let term: Int64
            let remainingSeconds: Double
        }

        struct Participant: Sendable {
            let identifier: String
            let role: String
            let ageSeconds: Double
            let fresh: Bool
            let hasWebUI: Bool
        }

        struct Event: Sendable {
            let time: Date
            let action: String
            let participant: String
            let term: Int64
        }

        struct Service: Sendable {
            let identifier: String
            let kind: String
            let leaseSeconds: Int
            let coordinationEnabled: Bool
            let allowedOriginCount: Int
            let locationCount: Int
            let freshLocationCount: Int
            let pendingPairingCount: Int
            let pendingWebsiteCount: Int
            let lease: Lease?
            let participants: [Participant]
            let events: [Event]
        }

        let generatedAt: Date
        let appVersion: String
        let appBuild: String
        let operatingSystem: String
        let architecture: String
        let authorityState: String
        let listenerPort: UInt16?
        let recoverySeconds: Double
        let hasAuthorityError: Bool
        let internetState: String
        let hasInternetError: Bool
        let services: [Service]
        var resources: Resources? = nil
    }

    static func buildReport(_ snapshot: Snapshot) -> String {
        let timestamp = ISO8601DateFormatter()
        timestamp.formatOptions = [.withInternetDateTime]

        var report = ""
        report += "=== Ruru Diagnostic Report ===\n"
        report += "Generated: \(timestamp.string(from: snapshot.generatedAt))\n"
        report += "App: \(snapshot.appVersion) (build \(snapshot.appBuild))\n"
        report += "OS: \(snapshot.operatingSystem) · arch \(snapshot.architecture)\n\n"

        report += "=== Process resources ===\n"
        report += "residentBytes=\(snapshot.resources?.residentBytes.map(String.init) ?? "unavailable")"
        report += " physicalFootprintBytes=\(snapshot.resources?.physicalFootprintBytes.map(String.init) ?? "unavailable")"
        report += " processAge=\(snapshot.resources?.processAgeSeconds.map(duration) ?? "unavailable")\n"
        report += "Physical footprint includes compressed memory charged to Ruru. These are process measurements, not the DuckDB memory budget.\n\n"

        report += "=== Authority ===\n"
        report += "state=\(snapshot.authorityState)"
        report += " listener=\(snapshot.listenerPort.map { "port \($0)" } ?? "not listening")"
        report += " recovery=\(duration(snapshot.recoverySeconds))"
        report += " authorityError=\(snapshot.hasAuthorityError ? "present" : "none")\n"
        report += "internet=\(snapshot.internetState) internetError=\(snapshot.hasInternetError ? "present" : "none")\n\n"

        report += "=== Services (\(snapshot.services.count)) ===\n"
        if snapshot.services.isEmpty {
            report += "(none configured)\n"
        }
        for service in snapshot.services {
            report += "[\(service.identifier)] kind=\(service.kind) leaseLength=\(service.leaseSeconds)s"
            report += " coordination=\(service.coordinationEnabled ? "enabled" : "disabled")"
            report += " allowedOrigins=\(service.allowedOriginCount)"
            report += " locations=\(service.locationCount) freshLocations=\(service.freshLocationCount)"
            report += " pendingPairings=\(service.pendingPairingCount) pendingWebsites=\(service.pendingWebsiteCount)\n"
            if let lease = service.lease {
                report += "  lease owner=\(lease.owner ?? "none") term=\(lease.term) remaining=\(duration(lease.remainingSeconds))\n"
            } else {
                report += "  lease=unavailable\n"
            }
            if service.participants.isEmpty {
                report += "  participants=(none reported)\n"
            } else {
                for participant in service.participants {
                    report += "  participant=\(participant.identifier) role=\(participant.role)"
                    report += " contact=\(participant.fresh ? "fresh" : "stale") age=\(duration(participant.ageSeconds))"
                    report += " webUI=\(participant.hasWebUI ? "reported" : "none")\n"
                }
            }
            if service.events.isEmpty {
                report += "  history=(none retained)\n"
            } else {
                report += "  history (newest first, \(service.events.count)):\n"
                for event in service.events {
                    report += "    \(timestamp.string(from: event.time)) action=\(event.action)"
                    report += " participant=\(event.participant) term=\(event.term)\n"
                }
            }
        }

        report += "\n=== Privacy ===\n"
        report += "Service and participant labels are local aliases. The report excludes bearer tokens, Keychain values, tunnel/API credentials, hostnames, URLs, and raw error text.\n"
        return report
    }

    static func defaultFilename(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "Ruru-diagnostics-\(formatter.string(from: date)).txt"
    }

    private static func duration(_ seconds: Double) -> String {
        let value = max(0, Int(seconds.rounded(.down)))
        if value < 60 { return "\(value)s" }
        if value < 3_600 { return "\(value / 60)m \(value % 60)s" }
        return "\(value / 3_600)h \((value % 3_600) / 60)m"
    }
}
