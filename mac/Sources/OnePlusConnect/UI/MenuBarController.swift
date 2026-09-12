import AppKit
import SwiftUI
import Combine

/// The menu bar item (PRD §35).
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let model = AppModel.shared
    private var cancellables = Set<AnyCancellable>()

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()
        model.$connection.sink { [weak self] _ in self?.updateIcon() }.store(in: &cancellables)
        model.$session.sink { [weak self] _ in self?.updateIcon() }.store(in: &cancellables)
        model.$lastError.sink { [weak self] err in
            guard let err = err else { return }
            self?.showError(err)
        }.store(in: &cancellables)
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let symbol: String
        switch model.session {
        case .streaming: symbol = "ipad.and.arrow.forward"
        case .starting, .paused: symbol = "ipad.badge.play"
        case .idle: symbol = model.connection.isReady ? "ipad" : "ipad.slash"
        }
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "One+Connect") {
            img.isTemplate = true
            button.image = img
        } else {
            button.title = "◉"
        }
        button.toolTip = "One+Connect — \(model.connection.shortTitle)"
        button.image?.accessibilityDescription = model.connection.linkKind.map { "One+Connect via \($0.title)" } ?? "One+Connect"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild()
    }

    private func rebuild() {
        menu.removeAllItems()
        let prefs = Preferences.shared

        let header = NSMenuItem(title: "One+Connect", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let endpoint = model.connection.device
        let device = endpoint?.displayName ?? "OnePlus Pad Go 2"
        menu.addItem(disabled(endpoint.map { "\(device) · \($0.linkDescription)" } ?? device))
        menu.addItem(disabled("   " + model.connection.shortTitle))
        if !model.connection.isReady {
            menu.addItem(disabled("   " + model.connection.message))
        }
        if model.session.isActive {
            menu.addItem(disabled("   " + model.session.title))
        }
        if !model.permissionsReady {
            menu.addItem(disabled("   ⚠ Permissions missing — open Setup Assistant"))
        }
        if endpoint?.kind != .wifi {
            let seen = Core.shared.connection.discoveredTablets
            if !seen.isEmpty, !model.connection.isReady {
                menu.addItem(disabled("   Wi-Fi: " + seen.map { "\($0.name) (\($0.host))" }.joined(separator: ", ")))
            }
        }
        menu.addItem(.separator())

        // Link choice (a switch, not a fallback: Wi-Fi stays wireless even with the cable in)
        let linkItem = NSMenuItem(title: "Connect over", action: nil, keyEquivalent: "")
        let linkMenu = NSMenu()
        for m in LinkMode.allCases {
            let it = NSMenuItem(title: m.title, action: #selector(selectLinkMode(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = m.rawValue
            it.state = prefs.linkMode == m ? .on : .off
            linkMenu.addItem(it)
        }
        linkItem.submenu = linkMenu
        menu.addItem(linkItem)

        // Display mode
        let modeItem = NSMenuItem(title: "Display", action: nil, keyEquivalent: "")
        let modeMenu = NSMenu()
        for m in SessionMode.allCases {
            let it = NSMenuItem(title: m.title, action: #selector(selectMode(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = m.rawValue
            it.state = prefs.mode == m ? .on : .off
            if m == .extend && !Core.shared.displayBackend.isAvailable {
                it.isEnabled = false
                it.title = "Extended (unavailable on this macOS)"
            }
            modeMenu.addItem(it)
        }
        modeItem.submenu = modeMenu
        menu.addItem(modeItem)

        // Quality
        let qItem = NSMenuItem(title: "Quality", action: nil, keyEquivalent: "")
        let qMenu = NSMenu()
        for p in QualityPreset.all {
            let it = NSMenuItem(title: "\(p.title) — \(p.width)×\(p.height), \(p.bitrate / 1_000_000) Mbps", action: #selector(selectPreset(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = p.key
            it.state = prefs.presetKey == p.key ? .on : .off
            qMenu.addItem(it)
        }
        let custom = NSMenuItem(title: "Custom (see Preferences)", action: #selector(selectPreset(_:)), keyEquivalent: "")
        custom.target = self
        custom.representedObject = "custom"
        custom.state = prefs.presetKey == "custom" ? .on : .off
        qMenu.addItem(custom)
        qMenu.addItem(.separator())
        let bitrateHeader = disabled("Bitrate")
        qMenu.addItem(bitrateHeader)
        for mbps in [0, 10, 15, 20, 30, 40, 60, 80] {
            let it = NSMenuItem(title: mbps == 0 ? "Automatic (preset)" : "\(mbps) Mbps", action: #selector(selectBitrate(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = mbps
            it.state = prefs.bitrateOverride == mbps * 1_000_000 ? .on : .off
            qMenu.addItem(it)
        }
        qMenu.addItem(.separator())
        qMenu.addItem(disabled("Codec"))
        for c in VideoCodecChoice.allCases {
            let it = NSMenuItem(title: c.title, action: #selector(selectCodec(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = c.rawValue
            it.state = prefs.codec == c ? .on : .off
            qMenu.addItem(it)
        }
        qItem.submenu = qMenu
        menu.addItem(qItem)

        // FPS
        let fpsItem = NSMenuItem(title: "FPS", action: nil, keyEquivalent: "")
        let fpsMenu = NSMenu()
        for f in [30, 60] {
            let it = NSMenuItem(title: "\(f)", action: #selector(selectFPS(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = f
            it.state = prefs.fps == f ? .on : .off
            fpsMenu.addItem(it)
        }
        fpsItem.submenu = fpsMenu
        menu.addItem(fpsItem)
        menu.addItem(.separator())

        if model.session.isActive {
            let stop = NSMenuItem(title: "Stop Sharing", action: #selector(stopSharing), keyEquivalent: "")
            stop.target = self
            menu.addItem(stop)
        } else {
            let start = NSMenuItem(title: "Start Sharing", action: #selector(startSharing), keyEquivalent: "")
            start.target = self
            start.isEnabled = model.connection.isReady
            menu.addItem(start)
        }
        menu.addItem(.separator())

        addAction("Diagnostics…", #selector(openDiagnostics))
        addAction("Preferences…", #selector(openPreferences))
        addAction("Setup Assistant…", #selector(openSetup))
        addAction("Open Log Folder", #selector(openLogs))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit One+Connect", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.isEnabled = false
        return it
    }

    private func addAction(_ title: String, _ sel: Selector) {
        let it = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        it.target = self
        menu.addItem(it)
    }

    // MARK: Actions

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let m = SessionMode(rawValue: raw) else { return }
        Preferences.shared.mode = m
        Core.shared.session.applyPreferencesChange()
    }

    @objc private func selectLinkMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let m = LinkMode(rawValue: raw) else { return }
        Preferences.shared.linkMode = m
        Core.shared.connection.refreshLinkPreferences()
    }

    @objc private func selectCodec(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let c = VideoCodecChoice(rawValue: raw) else { return }
        Preferences.shared.codec = c
        Core.shared.session.applyPreferencesChange()
    }

    @objc private func selectPreset(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        Preferences.shared.presetKey = key
        if let p = QualityPreset.named(key) { Preferences.shared.fps = p.fps }
        Core.shared.session.applyPreferencesChange()
    }

    @objc private func selectBitrate(_ sender: NSMenuItem) {
        guard let mbps = sender.representedObject as? Int else { return }
        Preferences.shared.bitrateOverride = mbps * 1_000_000
        Core.shared.session.applyPreferencesChange()
    }

    @objc private func selectFPS(_ sender: NSMenuItem) {
        guard let f = sender.representedObject as? Int else { return }
        Preferences.shared.fps = f
        Core.shared.session.applyPreferencesChange()
    }

    @objc private func startSharing() {
        if !model.permissionsReady {
            WindowManager.shared.showSetup()
        }
        model.startSharing()
    }

    @objc private func stopSharing() { model.stopSharing() }
    @objc private func openDiagnostics() { WindowManager.shared.showDiagnostics() }
    @objc private func openPreferences() { WindowManager.shared.showPreferences() }
    @objc private func openSetup() { WindowManager.shared.showSetup() }
    @objc private func openLogs() {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/OnePlusConnect")
        NSWorkspace.shared.open(dir)
    }
    @objc private func quit() {
        Core.shared.shutdown()
        NSApp.terminate(nil)
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "One+Connect"
        alert.informativeText = message
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
