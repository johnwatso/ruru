import Darwin
import Foundation

/// Held for the entire authority lifetime, including while its listener is paused.
/// A second process must never reset the first process's monotonic lease epoch.
final class DatabaseInstanceLock: @unchecked Sendable {
    private let descriptor: Int32

    init(url: URL) throws {
        descriptor = Darwin.open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw WitnessError.database("Cannot open the instance lock.") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            throw WitnessError.alreadyRunning
        }
    }

    deinit {
        flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }
}
