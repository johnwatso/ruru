import AppKit
import SwiftUI

/// Presentation-only inactivity. One app-local event monitor and at most one
/// sleeping task; lease requests and model polling never reset this clock.
@MainActor
final class RuruInteractionActivity: ObservableObject {
    @Published private(set) var leaseAnimationsEnabled = true

    private let timeout: Duration
    private let now: () -> ContinuousClock.Instant
    private var lastInteraction: ContinuousClock.Instant
    private var timeoutTask: Task<Void, Never>?
    private var eventMonitor: Any?

    init(timeout: Duration = .seconds(300), now: @escaping () -> ContinuousClock.Instant = { .now }) {
        self.timeout = timeout
        self.now = now
        lastInteraction = now()
    }

    deinit { timeoutTask?.cancel() }

    func startMonitoring() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp, .mouseMoved, .leftMouseDragged,
            .rightMouseDragged, .otherMouseDragged, .scrollWheel,
            .keyDown, .keyUp, .flagsChanged
        ]) { [weak self] event in
            // AppKit invokes local event monitors on the main thread.
            MainActor.assumeIsolated { self?.recordInteraction() }
            return event
        }
        recordInteraction()
    }

    func stopMonitoring() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        timeoutTask?.cancel()
        timeoutTask = nil
    }

    func recordInteraction() {
        lastInteraction = now()
        if !leaseAnimationsEnabled { leaseAnimationsEnabled = true }
        guard timeoutTask == nil else { return }
        timeoutTask = Task { [weak self] in
            // Input moves the deadline without replacing the sleeping task.
            while let remaining = self?.refreshIdleState() {
                do { try await Task.sleep(for: remaining) }
                catch { return }
            }
            self?.timeoutTask = nil
        }
    }

    /// Also permits deterministic deadline checks with a test clock.
    @discardableResult
    func refreshIdleState() -> Duration? {
        let remaining = timeout - lastInteraction.duration(to: now())
        guard remaining > .zero else {
            if leaseAnimationsEnabled { leaseAnimationsEnabled = false }
            return nil
        }
        return remaining
    }
}

private struct LeaseAnimationsEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var ruruLeaseAnimationsEnabled: Bool {
        get { self[LeaseAnimationsEnabledKey.self] }
        set { self[LeaseAnimationsEnabledKey.self] = newValue }
    }
}

/// Receive real pointer movement in Ruru's windows without a global monitor or
/// hover callbacks that could also be caused by passive layout changes.
struct RuruMouseActivityWindow: NSViewRepresentable {
    final class View: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.acceptsMouseMovedEvents = true
        }
    }

    func makeNSView(context: Context) -> View { View() }
    func updateNSView(_ nsView: View, context: Context) { }
}
