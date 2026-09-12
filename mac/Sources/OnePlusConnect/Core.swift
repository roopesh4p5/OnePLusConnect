import Foundation

/// Composition root for the non-UI services.
final class Core {
    static let shared = Core()

    let connection = ConnectionManager()
    let input = InputManager()
    let diagnostics = Diagnostics()
    let displayBackend: DisplayBackend = VirtualDisplayBackend()
    let session: SessionManager

    private init() {
        session = SessionManager(connection: connection, input: input, diagnostics: diagnostics, displayBackend: displayBackend)
    }

    func start() {
        Log.shared.info("One+Connect \(ConnectionManager.appVersion) starting (virtual display API available: \(displayBackend.isAvailable))")
        connection.start()
    }

    func shutdown() {
        session.stop()
        session.queue.sync {} // wait for the session teardown to finish
        connection.stop()
        displayBackend.destroy()
    }
}
