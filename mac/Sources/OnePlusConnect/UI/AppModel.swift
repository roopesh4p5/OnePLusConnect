import Foundation
import SwiftUI
import Combine

/// Main-thread mirror of service state for the menu bar and windows.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var connection: ConnectionState = .disconnected(message: ConnectionManager.noTabletMessage)
    @Published var session: SessionState = .idle
    @Published var lastError: String?
    @Published var diagnostics = DiagnosticsSnapshot()
    @Published var logLines: [Log.Entry] = []
    @Published var screenRecordingGranted = CaptureManager.hasPermission()
    @Published var accessibilityGranted = AXIsProcessTrusted()
    @Published var adbPath: String?

    private var permissionTimer: Timer?

    private init() {
        let core = Core.shared
        core.connection.observe { [weak self] state in
            Task { @MainActor in self?.connection = state; self?.adbPath = core.connection.adbPath }
        }
        core.session.onStateChange = { [weak self] state, error in
            Task { @MainActor in
                self?.session = state
                self?.lastError = error
            }
        }
        core.diagnostics.onUpdate = { [weak self] snap in
            Task { @MainActor in self?.diagnostics = snap }
        }
        logLines = Log.shared.snapshot()
        Log.shared.onAppend = { [weak self] entry in
            Task { @MainActor in
                guard let self = self else { return }
                self.logLines.append(entry)
                if self.logLines.count > 500 { self.logLines.removeFirst(self.logLines.count - 500) }
            }
        }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPermissions() }
        }
    }

    func refreshPermissions() {
        screenRecordingGranted = CaptureManager.hasPermission()
        accessibilityGranted = AXIsProcessTrusted()
    }

    var permissionsReady: Bool { screenRecordingGranted && accessibilityGranted }

    func startSharing() {
        lastError = nil
        Core.shared.session.start()
    }

    func stopSharing() {
        Core.shared.session.stop()
    }
}
