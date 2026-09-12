import AppKit
import SwiftUI

/// Creates and reuses the app's auxiliary windows.
@MainActor
final class WindowManager {
    static let shared = WindowManager()

    private var preferences: NSWindow?
    private var diagnostics: NSWindow?
    private var setup: NSWindow?

    func showPreferences() {
        show(&preferences, title: "One+Connect Preferences", size: NSSize(width: 520, height: 560)) { PreferencesView() }
    }

    func showDiagnostics() {
        show(&diagnostics, title: "One+Connect Diagnostics", size: NSSize(width: 640, height: 620)) { DiagnosticsView() }
    }

    func showSetup() {
        show(&setup, title: "Welcome to One+Connect", size: NSSize(width: 480, height: 420)) { SetupView() }
    }

    private func show<V: View>(_ slot: inout NSWindow?, title: String, size: NSSize, content: () -> V) {
        if slot == nil {
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = title
            w.isReleasedWhenClosed = false
            w.contentViewController = NSHostingController(rootView: content().environmentObject(AppModel.shared))
            w.center()
            slot = w
        }
        NSApp.activate(ignoringOtherApps: true)
        slot?.makeKeyAndOrderFront(nil)
    }
}
