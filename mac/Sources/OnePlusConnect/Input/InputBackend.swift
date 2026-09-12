import Foundation
import CoreGraphics
import ApplicationServices

/// Abstraction over how pointer events reach macOS (PRD §80): CGEvent now, virtual HID later.
protocol InputBackend: AnyObject {
    var isAuthorized: Bool { get }
    func moveTo(_ p: CGPoint)
    func leftDown(_ p: CGPoint, clickCount: Int)
    func leftDrag(_ p: CGPoint)
    func leftUp(_ p: CGPoint, clickCount: Int)
    func rightClick(_ p: CGPoint)
    func scroll(at p: CGPoint, dx: Double, dy: Double)
    func zoom(steps: Int)
}

/// Posts synthetic HID events via CoreGraphics. Requires the Accessibility permission.
final class CGEventInput: InputBackend {
    private let source = CGEventSource(stateID: .hidSystemState)

    var isAuthorized: Bool { AXIsProcessTrusted() }

    static func requestAuthorization() -> Bool {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    private func post(_ event: CGEvent?) {
        event?.post(tap: .cghidEventTap)
    }

    private func mouse(_ type: CGEventType, _ p: CGPoint, button: CGMouseButton, clickCount: Int = 1) -> CGEvent? {
        let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button)
        e?.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        return e
    }

    func moveTo(_ p: CGPoint) {
        post(mouse(.mouseMoved, p, button: .left))
    }

    func leftDown(_ p: CGPoint, clickCount: Int) {
        post(mouse(.mouseMoved, p, button: .left))
        post(mouse(.leftMouseDown, p, button: .left, clickCount: clickCount))
    }

    func leftDrag(_ p: CGPoint) {
        post(mouse(.leftMouseDragged, p, button: .left))
    }

    func leftUp(_ p: CGPoint, clickCount: Int) {
        post(mouse(.leftMouseUp, p, button: .left, clickCount: clickCount))
    }

    func rightClick(_ p: CGPoint) {
        post(mouse(.mouseMoved, p, button: .left))
        post(mouse(.rightMouseDown, p, button: .right))
        post(mouse(.rightMouseUp, p, button: .right))
    }

    func scroll(at p: CGPoint, dx: Double, dy: Double) {
        guard let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                              wheel1: Int32(dy.rounded()), wheel2: Int32(dx.rounded()), wheel3: 0) else { return }
        e.location = p
        post(e)
    }

    func zoom(steps: Int) {
        guard steps != 0 else { return }
        // '=' is keycode 24, '-' is keycode 27.
        let keyCode: CGKeyCode = steps > 0 ? 24 : 27
        for _ in 0..<abs(steps) {
            let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
            down?.flags = .maskCommand
            up?.flags = .maskCommand
            post(down)
            post(up)
        }
    }
}
