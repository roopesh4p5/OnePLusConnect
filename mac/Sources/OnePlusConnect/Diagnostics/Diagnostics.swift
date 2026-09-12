import Foundation

/// Live counters shown in the Diagnostics window (PRD §63).
struct DiagnosticsSnapshot {
    var transportConnected = false
    var throughputMbps: Double = 0
    var captureFps: Double = 0
    var encodeFps: Double = 0
    var encodeLatencyMs: Double = 0
    var decodeLatencyMs: Double = 0
    var tabletFps: Double = 0
    var droppedPercent: Double = 0
    var droppedOnMac = 0
    var droppedOnTablet = 0
    var inputLatencyMs: Double = 0
    var sessionLatencyMs: Double = 0
    var rttMs: Double = 0
    var pendingBytes = 0
    var battery: Int?
    var thermal: String?
    var streamSize = ""
    var bitrateMbps: Double = 0
}

/// Thread-safe accumulator sampled once per second.
final class Diagnostics {
    private let lock = NSLock()
    private var bytesSent = 0
    private var capturedFrames = 0
    private var encodedFrames = 0
    private var encodeLatencySum = 0.0
    private var droppedOnMac = 0
    private var lastSample = Clock.monotonic()
    private(set) var snapshot = DiagnosticsSnapshot()
    private var lastStats: StatsMessage?

    var onUpdate: ((DiagnosticsSnapshot) -> Void)?

    func recordCapture() { lock.lock(); capturedFrames += 1; lock.unlock() }
    func recordDrop() { lock.lock(); droppedOnMac += 1; lock.unlock() }
    func recordEncoded(bytes: Int, latencyMs: Double) {
        lock.lock(); encodedFrames += 1; bytesSent += bytes; encodeLatencySum += latencyMs; lock.unlock()
    }
    func recordStats(_ s: StatsMessage) { lock.lock(); lastStats = s; lock.unlock() }

    func resetCounters() {
        lock.lock()
        bytesSent = 0; capturedFrames = 0; encodedFrames = 0; encodeLatencySum = 0; droppedOnMac = 0
        lastStats = nil
        snapshot = DiagnosticsSnapshot()
        lastSample = Clock.monotonic()
        lock.unlock()
    }

    /// Called once a second by the session manager.
    func sample(connected: Bool, rttMs: Double, clockOffsetMicros: Double, inputLatencyMs: Double, pendingBytes: Int, streamSize: String, bitrate: Int) {
        lock.lock()
        let now = Clock.monotonic()
        let dt = max(0.001, now - lastSample)
        lastSample = now
        var s = snapshot
        s.transportConnected = connected
        s.throughputMbps = Double(bytesSent * 8) / dt / 1_000_000
        s.captureFps = Double(capturedFrames) / dt
        s.encodeFps = Double(encodedFrames) / dt
        s.encodeLatencyMs = encodedFrames > 0 ? encodeLatencySum / Double(encodedFrames) : 0
        s.droppedOnMac += droppedOnMac
        s.rttMs = rttMs
        s.inputLatencyMs = inputLatencyMs
        s.pendingBytes = pendingBytes
        s.streamSize = streamSize
        s.bitrateMbps = Double(bitrate) / 1_000_000
        if let t = lastStats {
            s.decodeLatencyMs = t.decodeLatencyMs ?? 0
            s.tabletFps = t.fps ?? 0
            s.droppedOnTablet = t.droppedFrames ?? s.droppedOnTablet
            s.battery = t.battery
            s.thermal = t.thermal
            if let raw = t.pipelineLatencyRawMs {
                // Tablet measured (its clock) minus Mac capture timestamp; remove estimated clock offset.
                s.sessionLatencyMs = max(0, raw - clockOffsetMicros / 1000)
            }
        }
        let total = capturedFrames + droppedOnMac
        s.droppedPercent = total > 0 ? Double(droppedOnMac + (lastStats?.droppedFrames ?? 0)) / Double(total) * 100 : 0
        bytesSent = 0; capturedFrames = 0; encodedFrames = 0; encodeLatencySum = 0; droppedOnMac = 0
        snapshot = s
        lock.unlock()
        onUpdate?(s)
    }
}
