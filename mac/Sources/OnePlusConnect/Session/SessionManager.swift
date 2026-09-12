import Foundation
import CoreGraphics
import CoreMedia
import CoreVideo

enum SessionState: Equatable {
    case idle
    case starting
    case streaming
    case paused(String)   // link lost, waiting to resume

    var title: String {
        switch self {
        case .idle: return "Not sharing"
        case .starting: return "Starting…"
        case .streaming: return "● Sharing"
        case .paused: return "⏸ Paused (reconnecting)"
        }
    }
    var isActive: Bool { self != .idle }
}

/// Session lifecycle: CONFIG handshake, capture → encode → send, touch → input,
/// keyframe recovery, orientation changes, pause/resume across reconnects (PRD §39/§40).
final class SessionManager {
    let queue = DispatchQueue(label: "oneplusconnect.session")

    private let connection: ConnectionManager
    private let input: InputManager
    private let diagnostics: Diagnostics
    private let displayBackend: DisplayBackend

    private(set) var state: SessionState = .idle {
        didSet { if state != oldValue { Log.shared.info("Session: \(state.title)"); onStateChange?(state, lastError) } }
    }
    private(set) var lastError: String? {
        didSet { if let e = lastError { Log.shared.error(e); onStateChange?(state, e) } }
    }
    var onStateChange: ((SessionState, String?) -> Void)?

    // Active session
    private var sessionID: UInt32 = 0
    private var mode: SessionMode = .mirror
    private var preset: QualityPreset = .balanced
    private var config: SessionConfigMessage?
    private var displayID: CGDirectDisplayID = 0
    private var capture: CaptureManager?
    private var encoder: H264Encoder?
    private var configTimeout: DispatchWorkItem?
    private var statsTimer: DispatchSourceTimer?
    private var displayGrace: DispatchWorkItem?
    private var tabletOrientation: Orientation = .landscape
    private var frameSequence: UInt32 = 0
    private var backlogThreshold = 128 * 1024
    private var pendingResume = false

    var currentConfig: SessionConfigMessage? { config }
    var currentDisplayID: CGDirectDisplayID { displayID }

    init(connection: ConnectionManager, input: InputManager, diagnostics: Diagnostics, displayBackend: DisplayBackend) {
        self.connection = connection
        self.input = input
        self.diagnostics = diagnostics
        self.displayBackend = displayBackend

        connection.packetHandler = { [weak self] packet in
            guard let self = self else { return }
            // Touch is latency-critical: handle off the session queue.
            if packet.type == .touch {
                if let frame = TouchFrame.decode(packet.payload, timestamp: packet.header.timestamp) {
                    self.input.handle(frame, clockOffsetMicros: self.connection.clockOffsetMicros)
                }
                return
            }
            self.queue.async { self.handle(packet) }
        }
        connection.onLinkLost = { [weak self] in
            self?.queue.async { self?.linkLost() }
        }
        connection.isSessionActive = { [weak self] in
            guard let self = self else { return false }
            return self.queue.sync { self.state.isActive }
        }
        connection.observe { [weak self] state in
            self?.queue.async { self?.connectionChanged(state) }
        }
    }

    // MARK: Public controls

    func start() {
        queue.async {
            self.lastError = nil
            self.begin(resume: false)
        }
    }

    func stop() {
        queue.async { self.teardown(notifyTablet: true, keepDisplay: false, next: .idle) }
    }

    /// Re-applies the current quality/mode preferences to a live session.
    func applyPreferencesChange() {
        queue.async {
            guard self.state == .streaming else { return }
            let p = Preferences.shared
            if p.mode != self.mode || p.preset != self.preset || p.fps != self.preset.fps || self.effectiveBitrate(p) != self.preset.bitrate {
                self.reconfigure(reason: "settings changed", recreateDisplay: p.mode != self.mode)
            }
        }
    }

    // MARK: Start / reconfigure

    /// Preset/override bitrate, capped on a Wi-Fi link unless the user set an explicit override.
    private func effectiveBitrate(_ prefs: Preferences) -> Int {
        let b = prefs.effectiveBitrate
        if connection.state.linkKind == .wifi, prefs.bitrateOverride == 0, prefs.wifiBitrateCapMbps > 0 {
            return min(b, prefs.wifiBitrateCapMbps * 1_000_000)
        }
        return b
    }

    private func begin(resume: Bool) {
        guard state == .idle || (resume && state.isPaused) else { return }
        guard let info = connection.state.deviceInfo else {
            lastError = "Tablet is not connected."
            return
        }
        guard CaptureManager.hasPermission() else {
            lastError = "One+Connect needs Screen Recording permission."
            return
        }
        if !input.isAuthorized {
            Log.shared.warn("Accessibility permission missing: touch input will be ignored until granted.")
        }

        let prefs = Preferences.shared
        mode = prefs.mode
        preset = prefs.preset
        var fps = prefs.fps
        if fps <= 0 { fps = 60 }
        let bitrate = effectiveBitrate(prefs)
        if bitrate != prefs.effectiveBitrate {
            Log.shared.info("Wi-Fi link: capping bitrate at \(bitrate / 1_000_000) Mbps (Preferences → Connection).")
        }
        preset = QualityPreset(key: preset.key, title: preset.title, width: preset.width, height: preset.height, fps: fps, bitrate: bitrate)
        tabletOrientation = resume ? tabletOrientation : info.orientation
        state = .starting
        configTimeout?.cancel()

        // Pick the source display.
        if mode == .extend {
            do {
                if let existing = displayBackend.displayID, DisplayInfo.isActive(existing) {
                    displayID = existing
                } else {
                    displayID = try displayBackend.create(virtualDisplayConfig(info: info))
                }
            } catch {
                state = .idle
                lastError = error.localizedDescription
                return
            }
        } else {
            displayID = DisplayInfo.mainDisplayID()
        }
        displayGrace?.cancel(); displayGrace = nil

        let targetID = displayID
        let currentSessionID = UInt32.random(in: 1...UInt32.max)
        sessionID = currentSessionID
        let mode = self.mode
        let preset = self.preset
        let orientation = tabletOrientation

        let native = nativePanelSize(info: info)
        let pinNative = mode == .extend && prefs.extendUseNativePixels
        let hiDPI = prefs.extendHiDPI
        let maxFpsAtNative = info.maxFpsAtNative ?? 0

        Task.detached { [weak self] in
            if mode == .extend {
                // Virtual displays take a moment before their mode is readable.
                _ = await CaptureManager.waitForDisplay(targetID, timeout: 6)
                // macOS picks its own (smaller) default mode; pin the framebuffer to the panel's pixels
                // so nothing is upscaled between the Mac and the tablet.
                if pinNative, DisplayInfo.applyMode(targetID, pixelWidth: native.0, pixelHeight: native.1, hiDPI: hiDPI) != nil {
                    try? await Task.sleep(nanoseconds: 400_000_000) // let the mode switch settle before measuring
                }
            }
            guard let self = self else { return }
            self.queue.async {
                guard self.state == .starting, self.sessionID == currentSessionID else { return }
                let (sw, sh) = DisplayInfo.pixelSize(of: targetID)
                let (w, h) = SessionManager.fit(sourceWidth: sw > 0 ? sw : preset.width, sourceHeight: sh > 0 ? sh : preset.height,
                                                boxWidth: orientation.isPortrait && mode == .extend ? preset.height : preset.width,
                                                boxHeight: orientation.isPortrait && mode == .extend ? preset.width : preset.height)
                var fps = preset.fps
                if maxFpsAtNative > 0 {
                    // Keep pixels-per-second within what the tablet's decoder advertised for its own panel.
                    let budget = native.0 * native.1 * maxFpsAtNative
                    if w * h * fps > budget {
                        fps = max(24, budget / (w * h))
                        Log.shared.warn("Tablet decoder tops out at \(maxFpsAtNative) fps for \(native.0)x\(native.1); using \(fps) fps for \(w)x\(h).")
                    }
                }
                if sw > 0, sh > 0, sw < w || sh < h {
                    Log.shared.warn("Source \(sw)x\(sh) is smaller than the \(w)x\(h) stream; the tablet image will be upscaled.")
                }
                let cfg = SessionConfigMessage(sessionId: currentSessionID, mode: mode, width: w, height: h, fps: fps,
                                               bitrate: preset.bitrate, codec: "h264", colorFormat: "nv12", orientation: orientation)
                self.config = cfg
                Log.shared.info("Session config: \(mode.rawValue) \(w)x\(h) @\(preset.fps) \(preset.bitrate / 1_000_000)Mbps source=\(sw)x\(sh) display=\(targetID)")
                self.connection.send(.control(.config, cfg, sessionID: currentSessionID))
                let timeout = DispatchWorkItem { [weak self] in
                    guard let self = self, self.state == .starting else { return }
                    self.teardown(notifyTablet: false, keepDisplay: false, next: .idle)
                    self.lastError = "The tablet did not confirm the session (timeout)."
                }
                self.configTimeout = timeout
                self.queue.asyncAfter(deadline: .now() + 6, execute: timeout)
            }
        }
    }

    /// Tablet panel pixels in the current tablet orientation.
    private func nativePanelSize(info: HelloAckMessage) -> (Int, Int) {
        var nativeW = info.displayWidth > 0 ? info.displayWidth : 2800
        var nativeH = info.displayHeight > 0 ? info.displayHeight : 1980
        if tabletOrientation.isPortrait, nativeW > nativeH { swap(&nativeW, &nativeH) }
        if !tabletOrientation.isPortrait, nativeW < nativeH { swap(&nativeW, &nativeH) }
        return (nativeW, nativeH)
    }

    private func virtualDisplayConfig(info: HelloAckMessage) -> VirtualDisplayConfig {
        let prefs = Preferences.shared
        let (nativeW, nativeH) = nativePanelSize(info: info)

        var modes: [VirtualDisplayMode] = []
        func add(_ w: Int, _ h: Int) {
            let m = tabletOrientation.isPortrait ? VirtualDisplayMode(width: min(w, h), height: max(w, h), refreshRate: 60)
                                                 : VirtualDisplayMode(width: max(w, h), height: min(w, h), refreshRate: 60)
            if !modes.contains(m) { modes.append(m) }
        }
        if prefs.extendUseNativePixels { add(nativeW, nativeH) }
        add(preset.width, preset.height)
        for p in QualityPreset.all where p.width <= nativeW { add(p.width, p.height) }
        return VirtualDisplayConfig(maxWidth: nativeW, maxHeight: nativeH, modes: modes, hiDPI: prefs.extendHiDPI)
    }

    /// Fits a source aspect ratio inside a box, rounding to even dimensions (encoder friendly).
    static func fit(sourceWidth: Int, sourceHeight: Int, boxWidth: Int, boxHeight: Int) -> (Int, Int) {
        let sa = Double(sourceWidth) / Double(sourceHeight)
        let ba = Double(boxWidth) / Double(boxHeight)
        var w: Double, h: Double
        if sa >= ba { w = Double(boxWidth); h = w / sa } else { h = Double(boxHeight); w = h * sa }
        let ew = max(16, Int(w.rounded()) & ~1)
        let eh = max(16, Int(h.rounded()) & ~1)
        return (ew, eh)
    }

    private func startPipeline() {
        guard let cfg = config else { return }
        do {
            let enc = try H264Encoder(width: cfg.width, height: cfg.height, fps: cfg.fps, bitrate: cfg.bitrate)
            enc.onFrame = { [weak self] frame in self?.sendEncoded(frame) }
            encoder = enc
        } catch {
            teardown(notifyTablet: true, keepDisplay: false, next: .idle)
            lastError = error.localizedDescription
            return
        }
        let bytesPerFrame = max(1, cfg.bitrate / 8 / max(1, cfg.fps))
        backlogThreshold = max(128 * 1024, bytesPerFrame * 4)
        frameSequence = 0

        let cap = CaptureManager(displayID: displayID, width: cfg.width, height: cfg.height, fps: cfg.fps)
        cap.onFrame = { [weak self] pixelBuffer, pts in
            guard let self = self, let enc = self.encoder else { return }
            if self.connection.pendingBytes > self.backlogThreshold {
                self.diagnostics.recordDrop()
                return
            }
            self.diagnostics.recordCapture()
            enc.encode(pixelBuffer: pixelBuffer, presentationTime: pts, captureTimestampMicros: Clock.nowMicros())
        }
        cap.onStopped = { [weak self] error in
            self?.queue.async {
                guard let self = self, self.state == .streaming else { return }
                self.teardown(notifyTablet: true, keepDisplay: false, next: .idle)
                self.lastError = "Screen capture stopped: \(error?.localizedDescription ?? "unknown error")"
            }
        }
        capture = cap
        input.refreshPreferences()
        input.setTargetDisplay(displayID)
        diagnostics.resetCounters()

        let sid = sessionID
        Task { [weak self] in
            do {
                try await cap.start()
                self?.queue.async {
                    guard let self = self, self.sessionID == sid else { return }
                    self.state = .streaming
                    self.encoder?.forceKeyframe()
                    self.startStatsTimer()
                }
            } catch {
                self?.queue.async {
                    guard let self = self, self.sessionID == sid else { return }
                    self.teardown(notifyTablet: true, keepDisplay: false, next: .idle)
                    self.lastError = error.localizedDescription
                }
            }
        }
    }

    private func sendEncoded(_ frame: EncodedFrame) {
        guard state == .streaming || state == .starting else { return }
        let sid = sessionID
        if frame.isKeyframe, let ps = frame.parameterSets {
            connection.send(Packet(type: .videoConfig, payload: ps, sessionID: sid, timestamp: frame.captureTimestampMicros))
        }
        frameSequence &+= 1
        var flags: PacketFlags = [.endOfFrame]
        if frame.isKeyframe { flags.insert(.keyframe) }
        let packet = Packet(type: frame.isKeyframe ? .keyframe : .video, payload: frame.data, flags: flags,
                            sessionID: sid, sequence: frameSequence, timestamp: frame.captureTimestampMicros)
        connection.send(packet)
        diagnostics.recordEncoded(bytes: frame.data.count + PacketHeader.size, latencyMs: frame.encodeLatencyMs)
    }

    /// Stops the pipeline and restarts the CONFIG handshake, keeping the tablet on the stream screen.
    private func reconfigure(reason: String, recreateDisplay: Bool) {
        guard state == .streaming || state == .starting else { return }
        Log.shared.info("Reconfiguring session (\(reason))")
        stopPipeline()
        if recreateDisplay || Preferences.shared.mode != .extend { displayBackend.destroy() }
        state = .idle
        begin(resume: false)
    }

    // MARK: Stop

    private func stopPipeline() {
        configTimeout?.cancel(); configTimeout = nil
        statsTimer?.cancel(); statsTimer = nil
        if let cap = capture {
            capture = nil
            Task { await cap.stop() }
        }
        encoder?.invalidate()
        encoder = nil
        input.reset()
    }

    private func teardown(notifyTablet: Bool, keepDisplay: Bool, next: SessionState) {
        let wasActive = state.isActive
        stopPipeline()
        if notifyTablet, wasActive, connection.state.isReady {
            connection.send(.control(.sessionStop, SessionStopMessage(reason: "user"), sessionID: sessionID))
        }
        if keepDisplay, displayBackend.displayID != nil {
            let grace = DispatchWorkItem { [weak self] in
                guard let self = self, self.state.isPaused || self.state == .idle else { return }
                Log.shared.info("Reconnect grace period elapsed; removing virtual display.")
                self.displayBackend.destroy()
                if self.state.isPaused { self.state = .idle }
            }
            displayGrace?.cancel()
            displayGrace = grace
            queue.asyncAfter(deadline: .now() + 30, execute: grace)
        } else {
            displayBackend.destroy()
        }
        config = nil
        state = next
    }

    // MARK: Connection events

    private func linkLost() {
        guard state.isActive else { return }
        let keep = Preferences.shared.keepDisplayOnReconnect && Preferences.shared.autoResume
        teardown(notifyTablet: false, keepDisplay: keep, next: .paused("Connection lost. Reconnecting…"))
        pendingResume = Preferences.shared.autoResume
    }

    private func connectionChanged(_ cs: ConnectionState) {
        if cs.isReady, state.isPaused, pendingResume {
            pendingResume = false
            Log.shared.info("Link restored; resuming session.")
            begin(resume: true)
        }
    }

    // MARK: Packets

    private func handle(_ packet: Packet) {
        switch packet.type {
        case .configAck:
            guard state == .starting, let ack = JSONCoding.decode(SessionReadyMessage.self, from: packet.payload), ack.sessionId == sessionID else { return }
            configTimeout?.cancel(); configTimeout = nil
            if ack.ok {
                startPipeline()
            } else {
                teardown(notifyTablet: false, keepDisplay: false, next: .idle)
                lastError = ack.error ?? "Tablet could not decode the selected video format."
            }
        case .requestKeyframe:
            encoder?.forceKeyframe()
        case .orientation:
            guard let msg = JSONCoding.decode(OrientationMessage.self, from: packet.payload) else { return }
            let changed = msg.orientation.isPortrait != tabletOrientation.isPortrait
            tabletOrientation = msg.orientation
            Log.shared.info("Tablet orientation: \(msg.orientation.rawValue)")
            if changed, mode == .extend, state == .streaming || state == .starting {
                reconfigure(reason: "orientation changed", recreateDisplay: true)
            }
        case .stats:
            if let s = JSONCoding.decode(StatsMessage.self, from: packet.payload) { diagnostics.recordStats(s) }
        case .sessionStop:
            if state.isActive {
                Log.shared.info("Tablet stopped sharing.")
                teardown(notifyTablet: false, keepDisplay: false, next: .idle)
            }
        case .error:
            if let e = JSONCoding.decode(ErrorMessage.self, from: packet.payload), state.isActive {
                if e.code == "decoder_failed" {
                    teardown(notifyTablet: false, keepDisplay: false, next: .idle)
                    lastError = "Tablet could not decode the selected video format. (\(e.message))"
                }
            }
        case .gesture, .stylus:
            break // Phase 2
        default:
            break
        }
    }

    private func startStatsTimer() {
        statsTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1.0)
        t.setEventHandler { [weak self] in
            guard let self = self, let cfg = self.config else { return }
            self.diagnostics.sample(connected: self.connection.state.isReady,
                                    rttMs: self.connection.rttMillis,
                                    clockOffsetMicros: self.connection.clockOffsetMicros,
                                    inputLatencyMs: self.inputLatency(),
                                    pendingBytes: self.connection.pendingBytes,
                                    streamSize: "\(cfg.width)×\(cfg.height) @ \(cfg.fps)",
                                    bitrate: cfg.bitrate)
        }
        t.resume()
        statsTimer = t
    }

    private func inputLatency() -> Double {
        input.queue.sync { input.lastInputLatencyMs }
    }
}

extension SessionState {
    var isPaused: Bool { if case .paused = self { return true } else { return false } }
}
