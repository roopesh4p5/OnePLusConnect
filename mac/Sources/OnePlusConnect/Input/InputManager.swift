import Foundation
import CoreGraphics

/// Maps normalized tablet touches onto a target display and drives the input backend.
final class InputManager {
    let queue = DispatchQueue(label: "oneplusconnect.input", qos: .userInteractive)
    private let backend: InputBackend
    private let recognizer: GestureRecognizer
    private var targetDisplay: CGDirectDisplayID = CGMainDisplayID()
    private var bounds: CGRect = .zero
    private(set) var lastInputLatencyMs: Double = 0
    private(set) var eventsHandled = 0
    private var warnedNoAccess = false

    init(backend: InputBackend = CGEventInput()) {
        self.backend = backend
        self.recognizer = GestureRecognizer(queue: queue)
        recognizer.emit = { [weak self] cmd in self?.perform(cmd) }
    }

    var isAuthorized: Bool { backend.isAuthorized }

    func setTargetDisplay(_ id: CGDirectDisplayID) {
        queue.async {
            self.targetDisplay = id
            self.bounds = DisplayInfo.bounds(of: id)
            Log.shared.info("Input target display \(id) bounds=\(self.bounds)")
        }
    }

    func refreshPreferences() {
        queue.async {
            let p = Preferences.shared
            self.recognizer.config.longPressRightClick = p.longPressRightClick
            self.recognizer.config.pinchEnabled = p.pinchZoom != .off
        }
    }

    func reset() {
        queue.async { self.recognizer.reset() }
    }

    func handle(_ frame: TouchFrame, clockOffsetMicros: Double) {
        queue.async {
            if !self.backend.isAuthorized {
                if !self.warnedNoAccess {
                    Log.shared.warn("Enable Accessibility permission to use tablet touch input.")
                    self.warnedNoAccess = true
                }
                return
            }
            if self.bounds.isEmpty { self.bounds = DisplayInfo.bounds(of: self.targetDisplay) }
            self.eventsHandled += 1
            let macNow = Double(Clock.nowMicros())
            let sentOnMacClock = Double(frame.timestampMicros) - clockOffsetMicros
            self.lastInputLatencyMs = max(0, (macNow - sentOnMacClock) / 1000)
            self.recognizer.handle(frame)
        }
    }

    private func point(_ x: Double, _ y: Double) -> CGPoint {
        let cx = min(max(x, 0), 1), cy = min(max(y, 0), 1)
        return CGPoint(x: bounds.origin.x + cx * bounds.width, y: bounds.origin.y + cy * bounds.height)
    }

    private func perform(_ cmd: GestureCommand) {
        let prefs = Preferences.shared
        switch cmd {
        case .move(let x, let y):
            backend.moveTo(point(x, y))
        case .leftDown(let x, let y, let clicks):
            backend.leftDown(point(x, y), clickCount: clicks)
        case .leftDrag(let x, let y):
            backend.leftDrag(point(x, y))
        case .leftUp(let x, let y, let clicks):
            backend.leftUp(point(x, y), clickCount: clicks)
        case .rightClick(let x, let y):
            backend.rightClick(point(x, y))
        case .scroll(let x, let y, let dx, let dy):
            let sign: Double = prefs.naturalScrolling ? 1 : -1
            let speed = prefs.scrollSpeed
            backend.scroll(at: point(x, y), dx: dx * bounds.width * sign * speed, dy: dy * bounds.height * sign * speed)
        case .zoom(let steps):
            if prefs.pinchZoom == .keyboard { backend.zoom(steps: steps) }
        }
    }
}
