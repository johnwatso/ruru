import WitnessKit

/// Display state only; never an authority or application synchronisation input.
enum WitnessLeasePresentation: Hashable {
    case renewing, late, critical, recovering, unowned

    init(lease: LeaseStatus?, leaseSeconds: Double, recovering: Bool) {
        if recovering { self = .recovering }
        else if (lease?.remainingSeconds ?? 0) <= 0 { self = .unowned }
        else if (lease?.remainingSeconds ?? 0) <= min(5, leaseSeconds / 6) { self = .critical }
        else if (lease?.remainingSeconds ?? 0) < leaseSeconds / 3 { self = .late }
        else { self = .renewing }
    }

    var idleCaption: String {
        switch self {
        case .renewing: "In Sync"
        case .late, .critical: "Renewal late"
        case .recovering: "Recovering"
        case .unowned: "No owner"
        }
    }

    var symbolName: String {
        switch self {
        case .renewing: "arrow.trianglehead.2.clockwise.rotate.90.circle.fill"
        case .late, .critical: "exclamationmark.triangle.fill"
        case .recovering: "clock.arrow.circlepath"
        case .unowned: "clock"
        }
    }
}
