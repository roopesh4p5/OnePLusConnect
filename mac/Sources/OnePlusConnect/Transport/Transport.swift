import Foundation
import Network

enum TransportState: Equatable {
    case idle
    case connecting
    case connected
    case failed(String)
    case closed
}

/// A reliable, ordered byte-stream transport carrying One+Connect packets.
/// One implementation, `TCPTransport`, serves both links: over USB it dials 127.0.0.1:<port>
/// (tunnelled by `adb forward`), over Wi-Fi it dials the tablet's LAN address directly.
protocol Transport: AnyObject {
    var onPacket: ((Packet) -> Void)? { get set }
    var onStateChange: ((TransportState) -> Void)? { get set }
    /// Bytes handed to the OS but not yet acknowledged as sent. Used for frame dropping.
    var pendingBytes: Int { get }
    func connect()
    func send(_ packet: Packet)
    func close()
}

/// TCP connection to <host>:<port>. host = 127.0.0.1 for the adb tunnel (USB), or the tablet's Wi-Fi IP.
final class TCPTransport: Transport {
    var onPacket: ((Packet) -> Void)?
    var onStateChange: ((TransportState) -> Void)?

    let host: String
    private let port: UInt16
    private let queue = DispatchQueue(label: "oneplusconnect.transport")
    private var connection: NWConnection?
    private let framer = PacketFramer()
    private var _pending = 0
    private let pendingLock = NSLock()
    private var closed = false

    var pendingBytes: Int {
        pendingLock.lock(); defer { pendingLock.unlock() }
        return _pending
    }

    init(host: String = "127.0.0.1", port: Int) {
        self.host = host
        self.port = UInt16(clamping: port)
    }

    func connect() {
        let params = NWParameters.tcp
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.connectionTimeout = 4
        }
        // Wi-Fi only: never let the tablet link wander onto cellular/VPN interfaces, and keep it IPv4.
        if host != "127.0.0.1" {
            params.prohibitedInterfaceTypes = [.cellular]
            if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 27183, using: params)
        connection = conn
        closed = false
        framer.reset()
        onStateChange?(.connecting)
        conn.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.onStateChange?(.connected)
                self.receiveHeader()
            case .failed(let err):
                self.finish(.failed(err.localizedDescription))
            case .cancelled:
                self.finish(.closed)
            case .waiting(let err):
                // Local forward port not reachable yet; treat as failure so the manager retries.
                self.finish(.failed(err.localizedDescription))
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    private func finish(_ state: TransportState) {
        guard !closed else { return }
        closed = true
        connection?.cancel()
        connection = nil
        onStateChange?(state)
    }

    func close() {
        queue.async { self.finish(.closed) }
    }

    func send(_ packet: Packet) {
        let data = packet.encoded()
        pendingLock.lock(); _pending += data.count; pendingLock.unlock()
        queue.async { [weak self] in
            guard let self = self, let conn = self.connection, !self.closed else {
                self?.pendingLock.lock(); self?._pending -= data.count; self?.pendingLock.unlock()
                return
            }
            conn.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self = self else { return }
                self.pendingLock.lock(); self._pending -= data.count; self.pendingLock.unlock()
                if let error = error {
                    Log.shared.warn("Transport send failed: \(error.localizedDescription)")
                    self.finish(.failed(error.localizedDescription))
                }
            })
        }
    }

    // MARK: Receive loop

    private func receiveHeader() {
        guard let conn = connection, !closed else { return }
        conn.receive(minimumIncompleteLength: PacketHeader.size, maximumLength: PacketHeader.size) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let error = error { self.finish(.failed(error.localizedDescription)); return }
            guard let data = data, data.count == PacketHeader.size else {
                if isComplete { self.finish(.closed) } else { self.finish(.failed("short read")) }
                return
            }
            do {
                let header = try PacketHeader.decode(data)
                if header.payloadLength == 0 {
                    self.onPacket?(Packet(header: header, payload: Data()))
                    self.receiveHeader()
                } else {
                    self.receivePayload(header: header)
                }
            } catch {
                Log.shared.error("Protocol error: \(error). Closing transport.")
                self.finish(.failed("protocol error"))
            }
        }
    }

    private func receivePayload(header: PacketHeader) {
        guard let conn = connection, !closed else { return }
        let length = Int(header.payloadLength)
        guard length <= framer.maxPayload else { finish(.failed("payload too large")); return }
        conn.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let error = error { self.finish(.failed(error.localizedDescription)); return }
            guard let data = data, data.count == length else {
                if isComplete { self.finish(.closed) } else { self.finish(.failed("short payload")) }
                return
            }
            self.onPacket?(Packet(header: header, payload: data))
            self.receiveHeader()
        }
    }
}
