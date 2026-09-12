import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Core.shared.start()
        menuBar = MenuBarController()
        if !AppModel.shared.permissionsReady {
            WindowManager.shared.showSetup()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Core.shared.shutdown()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
