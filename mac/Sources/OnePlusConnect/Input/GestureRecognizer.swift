import Foundation

/// Gesture commands produced from raw touch frames. Points are normalized (0...1).
enum GestureCommand {
    case move(x: Double, y: Double)
    case leftDown(x: Double, y: Double, clickCount: Int)
    case leftDrag(x: Double, y: Double)
    case leftUp(x: Double, y: Double, clickCount: Int)
    case rightClick(x: Double, y: Double)
    case scroll(x: Double, y: Double, dx: Double, dy: Double) // deltas normalized
    case zoom(steps: Int)
}

/// V1 touch mapping (PRD §28): tap → click, drag → mouse drag, long press → right click,
/// two-finger move → scroll, two-finger pinch → zoom steps. Three or more fingers cancel.
final class GestureRecognizer {
    struct Config {
        var tapSlop = 0.010          // normalized distance before a touch becomes a drag
        var longPressSeconds = 0.55
        var doubleTapSeconds = 0.35
        var doubleTapDistance = 0.03
        var pinchStep = 0.06         // normalized distance change per zoom step
        var scrollDeadZone = 0.002
        var longPressRightClick = true
        var pinchEnabled = true
    }

    var config = Config()
    var emit: ((GestureCommand) -> Void)?

    private enum Phase {
        case idle
        case single(start: (Double, Double), startTime: Double, last: (Double, Double))
        case dragging(last: (Double, Double))
        case longPressed
        case two(lastCentroid: (Double, Double), lastDistance: Double, zoomAccum: Double, scrolled: Bool)
        case ignore
    }

    private var phase: Phase = .idle
    private var longPressTimer: DispatchWorkItem?
    private let queue: DispatchQueue
    private var lastClickTime: Double = -1
    private var lastClickPos: (Double, Double) = (0, 0)
    private var pendingClickCount = 1

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func reset() {
        cancelLongPress()
        switch phase {
        case .dragging(let last):
            emit?(.leftUp(x: last.0, y: last.1, clickCount: 1))
        default: break
        }
        phase = .idle
    }

    /// Must be called on `queue`.
    func handle(_ frame: TouchFrame) {
        let now = Clock.monotonic()
        let count = frame.pointers.count
        let primary = frame.pointers.first.map { (Double($0.x), Double($0.y)) }

        if count >= 3 {
            switch phase {
            case .dragging(let last): emit?(.leftUp(x: last.0, y: last.1, clickCount: 1))
            default: break
            }
            cancelLongPress()
            phase = .ignore
            return
        }

        switch frame.action {
        case .down:
            guard let p = primary else { return }
            cancelLongPress()
            phase = .single(start: p, startTime: now, last: p)
            emit?(.move(x: p.0, y: p.1))
            scheduleLongPress(at: p)

        case .pointerDown:
            guard count == 2 else { return }
            cancelLongPress()
            switch phase {
            case .single, .idle:
                phase = .two(lastCentroid: centroid(frame), lastDistance: distance(frame), zoomAccum: 0, scrolled: false)
            case .dragging(let last):
                // Dragging with one finger and a second lands: end drag, start two-finger.
                emit?(.leftUp(x: last.0, y: last.1, clickCount: 1))
                phase = .two(lastCentroid: centroid(frame), lastDistance: distance(frame), zoomAccum: 0, scrolled: false)
            default:
                break
            }

        case .move:
            switch phase {
            case .single(let start, let startTime, _):
                guard let p = primary else { return }
                if dist(start, p) > config.tapSlop {
                    cancelLongPress()
                    let clicks = clickCount(for: start, at: startTime)
                    emit?(.leftDown(x: start.0, y: start.1, clickCount: clicks))
                    emit?(.leftDrag(x: p.0, y: p.1))
                    phase = .dragging(last: p)
                } else {
                    phase = .single(start: start, startTime: startTime, last: p)
                }
            case .dragging:
                guard let p = primary else { return }
                emit?(.leftDrag(x: p.0, y: p.1))
                phase = .dragging(last: p)
            case .two(let lastC, let lastD, var zoomAccum, var scrolled):
                guard count == 2 else { return }
                let c = centroid(frame)
                let d = distance(frame)
                let dx = c.0 - lastC.0
                let dy = c.1 - lastC.1
                var pinched = false
                if config.pinchEnabled {
                    zoomAccum += d - lastD
                    let steps = Int(zoomAccum / config.pinchStep)
                    if steps != 0 {
                        emit?(.zoom(steps: steps))
                        zoomAccum -= Double(steps) * config.pinchStep
                        pinched = true
                    }
                }
                if !pinched && (abs(dx) > config.scrollDeadZone || abs(dy) > config.scrollDeadZone) {
                    emit?(.scroll(x: c.0, y: c.1, dx: dx, dy: dy))
                    scrolled = true
                }
                phase = .two(lastCentroid: c, lastDistance: d, zoomAccum: zoomAccum, scrolled: scrolled)
            default:
                break
            }

        case .pointerUp:
            switch phase {
            case .two:
                // Remaining finger should not turn into a click/drag.
                phase = .ignore
            default:
                break
            }

        case .up:
            cancelLongPress()
            switch phase {
            case .single(let start, let startTime, _):
                let clicks = clickCount(for: start, at: startTime)
                emit?(.leftDown(x: start.0, y: start.1, clickCount: clicks))
                emit?(.leftUp(x: start.0, y: start.1, clickCount: clicks))
                lastClickTime = now
                lastClickPos = start
                pendingClickCount = clicks
            case .dragging(let last):
                let p = primary ?? last
                emit?(.leftUp(x: p.0, y: p.1, clickCount: 1))
                lastClickTime = -1
            default:
                break
            }
            phase = .idle

        case .cancel:
            cancelLongPress()
            if case .dragging(let last) = phase {
                emit?(.leftUp(x: last.0, y: last.1, clickCount: 1))
            }
            phase = .idle
        }
    }

    // MARK: Helpers

    private func clickCount(for p: (Double, Double), at time: Double) -> Int {
        if lastClickTime > 0, time - lastClickTime < config.doubleTapSeconds, dist(p, lastClickPos) < config.doubleTapDistance {
            return min(3, pendingClickCount + 1)
        }
        return 1
    }

    private func scheduleLongPress(at p: (Double, Double)) {
        guard config.longPressRightClick else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            if case .single(let start, _, let last) = self.phase, self.dist(start, last) <= self.config.tapSlop {
                self.emit?(.rightClick(x: start.0, y: start.1))
                self.phase = .longPressed
                self.lastClickTime = -1
            }
        }
        longPressTimer = item
        queue.asyncAfter(deadline: .now() + config.longPressSeconds, execute: item)
    }

    private func cancelLongPress() {
        longPressTimer?.cancel()
        longPressTimer = nil
    }

    private func dist(_ a: (Double, Double), _ b: (Double, Double)) -> Double {
        let dx = a.0 - b.0, dy = a.1 - b.1
        return (dx * dx + dy * dy).squareRoot()
    }

    private func centroid(_ f: TouchFrame) -> (Double, Double) {
        let n = Double(max(1, f.pointers.count))
        let sx = f.pointers.reduce(0.0) { $0 + Double($1.x) }
        let sy = f.pointers.reduce(0.0) { $0 + Double($1.y) }
        return (sx / n, sy / n)
    }

    private func distance(_ f: TouchFrame) -> Double {
        guard f.pointers.count >= 2 else { return 0 }
        let a = (Double(f.pointers[0].x), Double(f.pointers[0].y))
        let b = (Double(f.pointers[1].x), Double(f.pointers[1].y))
        return dist(a, b)
    }
}
