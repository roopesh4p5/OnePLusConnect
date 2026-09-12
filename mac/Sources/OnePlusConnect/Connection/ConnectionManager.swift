import Foundation

/// Which physical link the tablet is reached over.
enum LinkKind: String, Equatable {
    case usb
    case wifi

    var title: String { self == .usb ? "USB" : "Wi-Fi" }
}

/// Where the tablet app is reachable: the adb tunnel on localhost (USB) or a LAN address (Wi-Fi).
struct TabletEndpoint: Equatable {
    let kind: LinkKind
    let name: String        // e.g. "OnePlus Pad Go 2"
    let host: String        // 127.0.0.1 for USB
    let port: Int
    let serial: String?     // adb serial (USB only)

    var displayName: String { name }
    /// "USB" or "Wi-Fi 192.168.1.20".
    var linkDescription: String { kind == .usb ? "USB" : "Wi-Fi \(host)" }
}

/// Connection state machine (PRD §8 / §36), extended with the Wi-Fi link.
enum ConnectionState: Equatable {
    case disconnected(message: String)                          // no USB device and no tablet on Wi-Fi
    case usbDetected(message: String)                           // adb sees the device but it is unauthorized/offline
    case debuggerDetected(device: TabletEndpoint, message: String) // tablet reachable in principle, app not connected yet
    case appDetected(device: TabletEndpoint)                    // TCP connected
    case handshake(device: TabletEndpoint)
    case ready(device: TabletEndpoint, info: HelloAckMessage)
    case reconnecting(message: String)

    var shortTitle: String {
        switch self {
        case .disconnected: return "○ Tablet not connected"
        case .usbDetected: return "⚠ USB debugging required"
        case .debuggerDetected(let d, _): return d.kind == .usb ? "✓ USB connected" : "✓ Tablet found on Wi-Fi"
        case .appDetected(let d): return "✓ One+Connect detected (\(d.kind.title))"
        case .handshake(let d): return "… Handshake (\(d.kind.title))"
        case .ready(let d, _): return "✓ Ready to share via \(d.kind.title)"
        case .reconnecting: return "… Reconnecting"
        }
    }

    var message: String {
        switch self {
        case .disconnected(let m), .usbDetected(let m), .reconnecting(let m): return m
        case .debuggerDetected(_, let m): return m
        case .appDetected: return "Connecting to One+Connect on the tablet…"
        case .handshake: return "Negotiating capabilities…"
        case .ready(let d, let info): return "\(info.deviceModel) · \(info.displayWidth)×\(info.displayHeight) · \(d.linkDescription)"
        }
    }

    var isReady: Bool { if case .ready = self { return true } else { return false } }
    var device: TabletEndpoint? {
        switch self {
        case .debuggerDetected(let d, _), .appDetected(let d), .handshake(let d), .ready(let d, _): return d
        default: return nil
        }
    }
    var linkKind: LinkKind? { device?.kind }
    var deviceInfo: HelloAckMessage? { if case .ready(_, let i) = self { return i } else { return nil } }

    static func == (a: ConnectionState, b: ConnectionState) -> Bool {
        switch (a, b) {
        case (.disconnected(let x), .disconnected(let y)): return x == y
        case (.usbDetected(let x), .usbDetected(let y)): return x == y
        case (.debuggerDetected(let d1, let m1), .debuggerDetected(let d2, let m2)): return d1 == d2 && m1 == m2
        case (.appDetected(let d1), .appDetected(let d2)): return d1 == d2
        case (.handshake(let d1), .handshake(let d2)): return d1 == d2
        case (.ready(let d1, let i1), .ready(let d2, let i2)): return d1 == d2 && i1.deviceModel == i2.deviceModel && i1.displayWidth == i2.displayWidth && i1.displayHeight == i2.displayHeight
        case (.reconnecting(let x), .reconnecting(let y)): return x == y
        default: return false
        }
    }
}

/// Owns link selection, the transport, the HELLO handshake and keepalive.
/// Non-handshake packets are forwarded to `packetHandler` (the SessionManager).
///
/// Link policy follows `Preferences.linkMode`, which is a *choice*, not a fallback order:
///   .usb   → only the cable is ever used; the network is never touched.
///   .wifi  → only the network is used, even while a cable is plugged in.
///   .auto  → prefer the cable, use Wi-Fi when no authorized tablet is on USB, and move an idle
///            Wi-Fi link back to USB when a cable appears.
/// Changing the mode takes effect immediately: `refreshLinkPreferences()` drops a link that the
/// new mode forbids and the poll loop dials the other one.
final class ConnectionManager {
    static let appVersion = "0.1.0"
    static let protocolVersion = 1
    static let noTabletMessage = "Connect your OnePlus Pad Go 2 with a USB-C cable, or open One+Connect on the tablet while it is on the same Wi-Fi network."

    let queue = DispatchQueue(label: "oneplusconnect.connection")
    private(set) var state: ConnectionState = .disconnected(message: ConnectionManager.noTabletMessage) {
        didSet {
            if state != oldValue {
                Log.shared.info("Connection: \(state.shortTitle) — \(state.message)")
                for o in observers { o(state) }
            }
        }
    }

    private var observers: [(ConnectionState) -> Void] = []
    /// Registers a state observer (called on the connection queue).
    func observe(_ observer: @escaping (ConnectionState) -> Void) {
        queue.async { self.observers.append(observer); observer(self.state) }
    }
    /// Packets that are not part of the connection layer (video/touch/stats/...).
    var packetHandler: ((Packet) -> Void)?
    /// Fired when a previously ready link is lost (before reconnect attempts).
    var onLinkLost: (() -> Void)?
    /// Asked before moving an idle Wi-Fi link to USB; a live sharing session is never interrupted.
    var isSessionActive: (() -> Bool)?

    private var adb: ADB?
    private let discovery = WiFiDiscovery()
    private var transport: Transport?
    private var currentEndpoint: TabletEndpoint?
    private var pollTimer: DispatchSourceTimer?
    private var keepaliveTimer: DispatchSourceTimer?
    private var handshakeDeadline: DispatchWorkItem?
    private var lastPongMonotonic: Double = 0
    private var wasReady = false
    private var lostAt: Double = 0
    private var lostKind: LinkKind = .usb
    private var sequence: UInt32 = 0
    private var forwardedSerial: String?
    /// Link we are deliberately moving to; suppresses the "connection lost" path on close.
    private var switchingLink: LinkKind?
    private var pollCount = 0
    /// Last Wi-Fi endpoint that completed a handshake; retried after a drop even if beacons are late.
    private var lastWiFiEndpoint: TabletEndpoint?
    private var lastWiFiFailure: (host: String, at: Double)?

    /// NTP-style clock offset estimate: tabletClock ≈ macClock + offsetMicros.
    private(set) var clockOffsetMicros: Double = 0
    private(set) var rttMillis: Double = 0

    let deviceID: String = {
        let key = "device.id"
        if let v = UserDefaults.standard.string(forKey: key) { return v }
        let v = UUID().uuidString
        UserDefaults.standard.set(v, forKey: key)
        return v
    }()

    var pendingBytes: Int { transport?.pendingBytes ?? 0 }
    /// Link of the current (or connecting) transport.
    var linkKind: LinkKind? { currentEndpoint?.kind }
    /// Tablets currently announcing themselves on Wi-Fi (for the menu / preferences).
    var discoveredTablets: [DiscoveredTablet] { discovery.current() }

    // MARK: Lifecycle

    func start() {
        queue.async {
            self.locateADB()
            self.applyDiscoveryPreference()
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now(), repeating: 1.5)
            t.setEventHandler { [weak self] in self?.poll() }
            t.resume()
            self.pollTimer = t
        }
    }

    func stop() {
        queue.sync {
            pollTimer?.cancel(); pollTimer = nil
            keepaliveTimer?.cancel(); keepaliveTimer = nil
            transport?.close(); transport = nil
            discovery.stop()
            if forwardedSerial != nil { adb?.removeForward(localPort: Preferences.shared.adbPort) }
        }
    }

    func relocateADB() {
        queue.async { self.locateADB() }
    }

    /// Call after the link preferences change (mode, ports, manual address).
    /// A link the new mode forbids is dropped at once, so switching USB ⇄ Wi-Fi is immediate.
    func refreshLinkPreferences() {
        queue.async {
            self.applyDiscoveryPreference()
            let mode = Preferences.shared.linkMode
            if let ep = self.currentEndpoint {
                if let forced = mode.forcedKind, forced != ep.kind {
                    Log.shared.info("Link mode set to \(mode.shortTitle); leaving the \(ep.kind.title) link.")
                    self.switchingLink = forced
                    self.transport?.close()
                } else if ep.kind == .wifi, !self.state.isReady {
                    // A manual address change should take effect without waiting for the current attempt to die.
                    self.transport?.close()
                }
            }
        }
    }

    private func applyDiscoveryPreference() {
        let p = Preferences.shared
        if p.wifiEnabled { discovery.start(port: p.wifiDiscoveryPort) } else { discovery.stop() }
    }

    private func locateADB() {
        if let p = ADB.locate(preferred: Preferences.shared.adbPath) {
            if adb?.path != p { Log.shared.info("Using adb at \(p)") }
            adb = ADB(path: p)
        } else {
            adb = nil
            Log.shared.warn(ADBError.notFound.localizedDescription)
        }
    }

    var adbPath: String? { adb?.path }

    // MARK: Polling / link selection

    private enum USBProbe {
        case noADB(String)            // adb missing or failing
        case none                     // no cable
        case blocked(String)          // cable present, debugging unauthorized/offline/disabled
        case authorized(ADBDevice)
    }

    private func probeUSB() -> USBProbe {
        guard let adb = adb else {
            locateADB()
            guard self.adb != nil else { return .noADB(ADBError.notFound.localizedDescription) }
            return probeUSB()
        }
        let devices: [ADBDevice]
        do { devices = try adb.devices() } catch { return .noADB("adb error: \(error.localizedDescription)") }
        guard !devices.isEmpty else { return .none }

        // Prefer an authorized device, then a OnePlus-looking model.
        let sorted = devices.sorted { a, b in
            let ra = (a.state == .device ? 0 : 1, (a.model ?? "").lowercased().contains("oneplus") ? 0 : 1)
            let rb = (b.state == .device ? 0 : 1, (b.model ?? "").lowercased().contains("oneplus") ? 0 : 1)
            return ra < rb
        }
        let device = sorted[0]
        switch device.state {
        case .device: return .authorized(device)
        case .unauthorized: return .blocked("Unlock the tablet and allow USB debugging.")
        case .offline: return .blocked("Reconnect the USB cable or restart USB debugging.")
        case .other: return .blocked("Enable USB debugging in Android Developer Options.")
        }
    }

    private func poll() {
        pollCount &+= 1
        let mode = Preferences.shared.linkMode

        // While a transport is alive, the keepalive owns liveness. The only job here is to honour
        // the link choice: leave a link the mode forbids, and in .auto move an idle Wi-Fi link to USB.
        if transport != nil {
            guard let ep = currentEndpoint else { return }
            if let forced = mode.forcedKind, forced != ep.kind {
                Log.shared.info("Link mode is \(mode.shortTitle); leaving the \(ep.kind.title) link.")
                switchingLink = forced
                transport?.close()
            } else if mode == .auto, ep.kind == .wifi, pollCount % 3 == 0, isSessionActive?() != true,
                      case .authorized(let dev) = probeUSB() {
                Log.shared.info("USB cable detected (\(dev.displayName)); moving the link from Wi-Fi to USB.")
                switchingLink = .usb
                transport?.close()
            }
            return
        }

        // ---- Wi-Fi only: the cable is ignored on purpose, so adb is never even asked. ----
        if mode == .wifi {
            if let endpoint = wifiCandidate() {
                connectWiFi(endpoint)
            } else {
                setState(reconnectingOr(.disconnected(message: "Wi-Fi is selected in One+Connect. Open One+Connect on the tablet and keep it on the same network as this Mac\(Preferences.shared.wifiManualHost.isEmpty ? "" : " (looking for \(Preferences.shared.wifiManualHost))").")))
            }
            return
        }

        // ---- Cable first ----
        let probe = probeUSB()
        if case .authorized(let device) = probe {
            connectUSB(device)
            return
        }

        let usbHint: String
        switch probe {
        case .noADB(let m): usbHint = m
        case .blocked(let m): usbHint = m
        case .none, .authorized: usbHint = ""
        }

        // ---- .auto: no cable, so try the network ----
        if mode == .auto, let endpoint = wifiCandidate() {
            connectWiFi(endpoint)
            return
        }

        // Nothing to connect to yet: explain what is missing.
        let wifiAllowed = mode == .auto
        if case .blocked(let m) = probe {
            setState(reconnectingOr(.usbDetected(message: m + (wifiAllowed ? " (or use Wi-Fi: open One+Connect on the tablet on the same network)" : ""))))
        } else if !usbHint.isEmpty && !wifiAllowed {
            setState(.disconnected(message: usbHint))
        } else if !wifiAllowed {
            setState(reconnectingOr(.disconnected(message: "USB is selected in One+Connect. Connect your OnePlus Pad Go 2 using a USB-C cable.")))
        } else {
            let hint = usbHint.isEmpty ? "" : " (USB: \(usbHint))"
            setState(reconnectingOr(.disconnected(message: ConnectionManager.noTabletMessage + hint)))
        }
    }

    private func connectUSB(_ device: ADBDevice) {
        guard let adb = adb else { return }
        let port = Preferences.shared.adbPort
        let endpoint = TabletEndpoint(kind: .usb, name: device.displayName, host: "127.0.0.1", port: port, serial: device.serial)
        do {
            try adb.forward(serial: device.serial, localPort: port, remotePort: port)
            forwardedSerial = device.serial
        } catch {
            setState(.debuggerDetected(device: endpoint, message: "adb forward failed: \(error.localizedDescription)"))
            return
        }
        if case .debuggerDetected(let d, _) = state, d == endpoint {} else {
            setState(reconnectingOr(.debuggerDetected(device: endpoint, message: "Open One+Connect on your tablet.")))
        }
        openTransport(endpoint)
    }

    /// Picks the Wi-Fi target: manual address wins, then the freshest beacon, then the last good endpoint.
    private func wifiCandidate() -> TabletEndpoint? {
        let p = Preferences.shared
        let port = p.adbPort
        let manual = p.wifiManualHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if !manual.isEmpty {
            var host = manual, prt = port
            if let colon = manual.lastIndex(of: ":"), let n = Int(manual[manual.index(after: colon)...]) {
                host = String(manual[..<colon]); prt = n
            }
            let name = discovery.current().first { $0.host == host }?.name ?? "Tablet at \(host)"
            return TabletEndpoint(kind: .wifi, name: name, host: host, port: prt, serial: nil)
        }
        let now = Clock.monotonic()
        let fresh = discovery.current(maxAge: 6).filter { t in
            // Back off a host that just refused us so a second tablet (if any) gets a turn.
            if let f = lastWiFiFailure, f.host == t.host, now - f.at < 4 { return false }
            return true
        }
        if let t = fresh.first {
            return TabletEndpoint(kind: .wifi, name: t.name, host: t.host, port: t.port, serial: nil)
        }
        if let last = lastWiFiEndpoint, wasReady, now - lostAt < 20 {
            return last // beacon pauses while the tablet still thinks we are connected; retry the known address
        }
        return nil
    }

    private func connectWiFi(_ endpoint: TabletEndpoint) {
        if case .debuggerDetected(let d, _) = state, d == endpoint {} else {
            setState(reconnectingOr(.debuggerDetected(device: endpoint, message: "Connecting to \(endpoint.name) over Wi-Fi (\(endpoint.host))…")))
        }
        openTransport(endpoint)
    }

    /// Keeps the RECONNECTING label for a few seconds after a drop instead of flashing DISCONNECTED.
    private func reconnectingOr(_ fallback: ConnectionState) -> ConnectionState {
        if wasReady, Clock.monotonic() - lostAt < 8 {
            return .reconnecting(message: "\(lostKind.title) connection lost. Reconnecting…")
        }
        return fallback
    }

    private func setState(_ new: ConnectionState) {
        state = new
    }

    // MARK: Transport / handshake

    private func openTransport(_ endpoint: TabletEndpoint) {
        let t = TCPTransport(host: endpoint.host, port: endpoint.port)
        transport = t
        currentEndpoint = endpoint
        t.onPacket = { [weak self] packet in
            self?.queue.async { self?.handle(packet: packet) }
        }
        t.onStateChange = { [weak self] ts in
            self?.queue.async { self?.transportChanged(ts, endpoint: endpoint) }
        }
        t.connect()
    }

    private func transportChanged(_ ts: TransportState, endpoint: TabletEndpoint) {
        guard currentEndpoint == endpoint else { return } // stale callback from a replaced transport
        switch ts {
        case .connecting:
            break
        case .connected:
            setState(.appDetected(device: endpoint))
            sendHello(endpoint: endpoint)
        case .failed, .closed:
            let wasConnected = state.isReady
            transport = nil
            currentEndpoint = nil
            handshakeDeadline?.cancel(); handshakeDeadline = nil
            keepaliveTimer?.cancel(); keepaliveTimer = nil
            if let to = switchingLink {
                switchingLink = nil
                setState(.reconnecting(message: to == .usb ? "Switching to USB…" : "Switching to Wi-Fi…"))
            } else if wasConnected {
                wasReady = true
                lostAt = Clock.monotonic()
                lostKind = endpoint.kind
                Log.shared.warn("Link to tablet lost over \(endpoint.kind.title) (\(ts)).")
                onLinkLost?()
                setState(.reconnecting(message: "\(endpoint.kind.title) connection lost. Reconnecting…"))
            } else if endpoint.kind == .wifi {
                lastWiFiFailure = (endpoint.host, Clock.monotonic())
                if case .failed(let why) = ts {
                    setState(reconnectingOr(.debuggerDetected(device: endpoint, message: "Found \(endpoint.name) on Wi-Fi but could not connect (\(why)). Make sure both devices are on the same network and the tablet app is open.")))
                } else {
                    setState(reconnectingOr(.debuggerDetected(device: endpoint, message: "Open One+Connect on your tablet.")))
                }
            } else if case .debuggerDetected = state {
                // stay; message already asks to open the app
            } else {
                setState(reconnectingOr(.debuggerDetected(device: endpoint, message: "Open One+Connect on your tablet.")))
            }
        case .idle:
            break
        }
    }

    private func sendHello(endpoint: TabletEndpoint) {
        setState(.handshake(device: endpoint))
        let hello = HelloMessage(protocolVersion: ConnectionManager.protocolVersion,
                                 appVersion: ConnectionManager.appVersion,
                                 deviceId: deviceID,
                                 hostName: Host.current().localizedName ?? "Mac",
                                 capabilities: ["mirror", "extend", "touch", "h264", "hevc"],
                                 transport: endpoint.kind.rawValue)
        send(.control(.hello, hello))
        let deadline = DispatchWorkItem { [weak self] in
            guard let self = self, case .handshake = self.state else { return }
            Log.shared.warn("Handshake timed out; tablet app probably not running.")
            self.transport?.close()
        }
        handshakeDeadline = deadline
        queue.asyncAfter(deadline: .now() + 3, execute: deadline)
    }

    private func handle(packet: Packet) {
        switch packet.type {
        case .helloAck:
            handshakeDeadline?.cancel(); handshakeDeadline = nil
            guard let info = JSONCoding.decode(HelloAckMessage.self, from: packet.payload) else {
                Log.shared.error("Malformed HELLO_ACK")
                transport?.close()
                return
            }
            guard let device = state.device else { return }
            Log.shared.info("Tablet: \(info.deviceModel) \(info.displayWidth)x\(info.displayHeight) rates=\(info.refreshRates) codecs=\(info.codecs) touch=\(info.touch) stylus=\(info.stylus) link=\(device.linkDescription)")
            wasReady = false
            lastWiFiFailure = nil
            if device.kind == .wifi { lastWiFiEndpoint = device }
            lastPongMonotonic = Clock.monotonic()
            setState(.ready(device: device, info: info))
            startKeepalive()
        case .pong:
            if let pong = JSONCoding.decode(PongMessage.self, from: packet.payload) {
                let t4 = Clock.nowMicros()
                let rtt = Double(t4 &- pong.t1) - Double(pong.t3 &- pong.t2)
                let offset = (Double(Int64(bitPattern: pong.t2 &- pong.t1)) + Double(Int64(bitPattern: pong.t3 &- t4))) / 2
                rttMillis = max(0, rtt / 1000)
                clockOffsetMicros = clockOffsetMicros == 0 ? offset : (clockOffsetMicros * 0.8 + offset * 0.2)
            }
            lastPongMonotonic = Clock.monotonic()
        case .ping:
            if let ping = JSONCoding.decode(PingMessage.self, from: packet.payload) {
                let now = Clock.nowMicros()
                send(.control(.pong, PongMessage(t1: ping.t1, t2: now, t3: Clock.nowMicros())))
            }
        case .disconnect:
            Log.shared.info("Tablet requested disconnect.")
            transport?.close()
        case .error:
            if let e = JSONCoding.decode(ErrorMessage.self, from: packet.payload) {
                Log.shared.error("Tablet error \(e.code): \(e.message)")
            }
            packetHandler?(packet)
        default:
            packetHandler?(packet)
        }
    }

    private func startKeepalive() {
        keepaliveTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1.0)
        t.setEventHandler { [weak self] in
            guard let self = self, self.transport != nil else { return }
            // Wi-Fi jitters more than the cable: give it a longer grace before declaring the link dead.
            let grace: Double = self.currentEndpoint?.kind == .wifi ? 8 : 5
            if Clock.monotonic() - self.lastPongMonotonic > grace {
                Log.shared.warn("No PONG for \(Int(grace))s; dropping link.")
                self.transport?.close()
                return
            }
            self.send(.control(.ping, PingMessage(t1: Clock.nowMicros())))
        }
        t.resume()
        keepaliveTimer = t
    }

    // MARK: Sending

    func send(_ packet: Packet) {
        var p = packet
        sequence &+= 1
        p.header.sequence = sequence
        transport?.send(p)
    }

    /// Closes the current link; the poll loop will reconnect automatically.
    func dropLink() {
        queue.async { self.transport?.close() }
    }
}
