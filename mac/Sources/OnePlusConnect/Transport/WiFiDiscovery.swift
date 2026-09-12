import Foundation
import Darwin

/// A tablet that announced itself on the local network.
struct DiscoveredTablet: Equatable {
    let host: String
    let port: Int
    let name: String
    let lastSeen: Double   // Clock.monotonic()
}

/// Listens for the tablet app's UDP discovery beacon (JSON, broadcast every second on
/// `discoveryPort`, see PROTOCOL.md "Wi-Fi discovery"). Plain BSD socket so broadcast datagrams
/// are received reliably on every macOS version; no Bonjour dependency.
final class WiFiDiscovery {
    private let queue = DispatchQueue(label: "oneplusconnect.discovery")
    private var source: DispatchSourceRead?
    private var fd: Int32 = -1
    private var boundPort: Int = 0
    private let lock = NSLock()
    private var tablets: [String: DiscoveredTablet] = [:]

    /// Tablets seen within `maxAge` seconds, most recent first.
    func current(maxAge: Double = 6) -> [DiscoveredTablet] {
        lock.lock(); defer { lock.unlock() }
        let now = Clock.monotonic()
        tablets = tablets.filter { now - $0.value.lastSeen < 60 }
        return tablets.values.filter { now - $0.lastSeen < maxAge }.sorted { $0.lastSeen > $1.lastSeen }
    }

    func start(port: Int) {
        queue.async {
            if self.fd >= 0 && self.boundPort == port { return }
            self.closeSocket()
            self.open(port: port)
        }
    }

    func stop() {
        queue.async { self.closeSocket() }
    }

    private func open(port: Int) {
        let sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else { Log.shared.warn("Wi-Fi discovery: socket() failed (\(errno))"); return }
        var one: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(sock, SOL_SOCKET, SO_REUSEPORT, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(sock, SOL_SOCKET, SO_BROADCAST, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(sock, F_SETFL, fcntl(sock, F_GETFL) | O_NONBLOCK)

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(clamping: port)).bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard rc == 0 else {
            Log.shared.warn("Wi-Fi discovery: could not listen on UDP \(port) (errno \(errno)). Use the manual tablet address in Preferences.")
            close(sock)
            return
        }
        fd = sock
        boundPort = port
        let src = DispatchSource.makeReadSource(fileDescriptor: sock, queue: queue)
        src.setEventHandler { [weak self] in self?.drain() }
        src.setCancelHandler { close(sock) }
        src.resume()
        source = src
        Log.shared.info("Wi-Fi discovery listening on UDP \(port)")
    }

    private func closeSocket() {
        source?.cancel()   // cancel handler closes the fd
        source = nil
        fd = -1
        boundPort = 0
    }

    private func drain() {
        var buffer = [UInt8](repeating: 0, count: 2048)
        while true {
            var from = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &fromLen) }
            }
            if n <= 0 { return }
            var ipBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var sin = from.sin_addr
            inet_ntop(AF_INET, &sin, &ipBuf, socklen_t(INET_ADDRSTRLEN))
            let sender = String(cString: ipBuf)
            handle(Data(buffer[0..<n]), from: sender)
        }
    }

    private func handle(_ data: Data, from sender: String) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["app"] as? String == "oneplusconnect" else { return }
        let port = obj["port"] as? Int ?? 27183
        let name = obj["name"] as? String ?? "Android tablet"
        // Trust the sender address over the advertised one (NAT/multi-homed tablets).
        let host = sender
        lock.lock()
        let isNew = tablets[host] == nil
        tablets[host] = DiscoveredTablet(host: host, port: port, name: name, lastSeen: Clock.monotonic())
        lock.unlock()
        if isNew { Log.shared.info("Wi-Fi: found \(name) at \(host):\(port)") }
    }
}
