import Foundation

/// One+Connect wire protocol. All integers are big-endian.
///
/// Header (28 bytes):
///   u32 MAGIC          "OPC1"
///   u8  VERSION        1
///   u8  TYPE           PacketType
///   u8  FLAGS
///   u8  RESERVED
///   u32 SESSION_ID
///   u32 SEQUENCE
///   u64 TIMESTAMP      microseconds since Unix epoch (sender clock)
///   u32 PAYLOAD_LENGTH
enum PacketType: UInt8 {
    case hello = 0x01
    case helloAck = 0x02
    case config = 0x03
    case configAck = 0x04
    case sessionStop = 0x06

    case video = 0x10
    case keyframe = 0x11
    case videoConfig = 0x12
    case requestKeyframe = 0x13

    case touch = 0x20
    case gesture = 0x21
    case stylus = 0x22
    case orientation = 0x23

    case ping = 0x30
    case pong = 0x31
    case stats = 0x32

    case error = 0x40
    case disconnect = 0x41
}

struct PacketFlags: OptionSet {
    let rawValue: UInt8
    static let keyframe = PacketFlags(rawValue: 1 << 0)
    static let endOfFrame = PacketFlags(rawValue: 1 << 1)
}

struct PacketHeader {
    static let magic: UInt32 = 0x4F50_4331 // "OPC1"
    static let version: UInt8 = 1
    static let size = 28

    var type: PacketType
    var flags: PacketFlags = []
    var sessionID: UInt32 = 0
    var sequence: UInt32 = 0
    var timestamp: UInt64 = 0
    var payloadLength: UInt32 = 0

    func encoded() -> Data {
        var data = Data(capacity: PacketHeader.size)
        data.appendBE(PacketHeader.magic)
        data.append(PacketHeader.version)
        data.append(type.rawValue)
        data.append(flags.rawValue)
        data.append(0)
        data.appendBE(sessionID)
        data.appendBE(sequence)
        data.appendBE(timestamp)
        data.appendBE(payloadLength)
        return data
    }

    enum DecodeError: Error { case badMagic, badVersion, unknownType(UInt8), short }

    static func decode(_ data: Data) throws -> PacketHeader {
        guard data.count >= size else { throw DecodeError.short }
        var r = BinaryReader(data)
        guard r.u32() == magic else { throw DecodeError.badMagic }
        guard r.u8() == version else { throw DecodeError.badVersion }
        let rawType = r.u8()
        guard let type = PacketType(rawValue: rawType) else { throw DecodeError.unknownType(rawType) }
        let flags = PacketFlags(rawValue: r.u8())
        _ = r.u8()
        let sessionID = r.u32()
        let sequence = r.u32()
        let timestamp = r.u64()
        let length = r.u32()
        return PacketHeader(type: type, flags: flags, sessionID: sessionID, sequence: sequence, timestamp: timestamp, payloadLength: length)
    }
}

struct Packet {
    var header: PacketHeader
    var payload: Data

    init(type: PacketType, payload: Data = Data(), flags: PacketFlags = [], sessionID: UInt32 = 0, sequence: UInt32 = 0, timestamp: UInt64 = Clock.nowMicros()) {
        header = PacketHeader(type: type, flags: flags, sessionID: sessionID, sequence: sequence, timestamp: timestamp, payloadLength: UInt32(payload.count))
        self.payload = payload
    }

    init(header: PacketHeader, payload: Data) {
        self.header = header
        self.payload = payload
    }

    func encoded() -> Data {
        var h = header
        h.payloadLength = UInt32(payload.count)
        var d = h.encoded()
        d.append(payload)
        return d
    }

    var type: PacketType { header.type }
}

/// Accumulates bytes from a stream and yields complete packets.
final class PacketFramer {
    private var buffer = Data()
    var maxPayload = 32 * 1024 * 1024

    enum FramerError: Error { case payloadTooLarge(UInt32) }

    func append(_ data: Data) throws -> [Packet] {
        buffer.append(data)
        var packets: [Packet] = []
        while buffer.count >= PacketHeader.size {
            let header = try PacketHeader.decode(buffer.prefix(PacketHeader.size))
            guard header.payloadLength <= maxPayload else { throw FramerError.payloadTooLarge(header.payloadLength) }
            let total = PacketHeader.size + Int(header.payloadLength)
            guard buffer.count >= total else { break }
            let payload = buffer.subdata(in: PacketHeader.size..<total)
            packets.append(Packet(header: header, payload: payload))
            buffer.removeSubrange(0..<total)
        }
        return packets
    }

    func reset() { buffer.removeAll() }
}

enum Clock {
    /// Microseconds since Unix epoch (wall clock, shared base with the tablet).
    static func nowMicros() -> UInt64 {
        UInt64(Date().timeIntervalSince1970 * 1_000_000)
    }
    /// Monotonic seconds, for intervals.
    static func monotonic() -> Double {
        var ts = timespec()
        clock_gettime(CLOCK_MONOTONIC_RAW, &ts)
        return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9
    }
}

// MARK: - Binary helpers

extension Data {
    mutating func appendBE(_ v: UInt16) { var b = v.bigEndian; Swift.withUnsafeBytes(of: &b) { append(contentsOf: $0) } }
    mutating func appendBE(_ v: UInt32) { var b = v.bigEndian; Swift.withUnsafeBytes(of: &b) { append(contentsOf: $0) } }
    mutating func appendBE(_ v: UInt64) { var b = v.bigEndian; Swift.withUnsafeBytes(of: &b) { append(contentsOf: $0) } }
    mutating func appendBE(_ v: Float) { appendBE(v.bitPattern) }
}

struct BinaryReader {
    private let data: Data
    private(set) var offset: Int

    init(_ data: Data) { self.data = data; self.offset = data.startIndex }

    var remaining: Int { data.endIndex - offset }

    mutating func u8() -> UInt8 {
        guard remaining >= 1 else { return 0 }
        let v = data[offset]; offset += 1; return v
    }
    mutating func u16() -> UInt16 {
        guard remaining >= 2 else { offset = data.endIndex; return 0 }
        var v: UInt16 = 0
        _ = Swift.withUnsafeMutableBytes(of: &v) { data.copyBytes(to: $0, from: offset..<offset + 2) }
        offset += 2; return UInt16(bigEndian: v)
    }
    mutating func u32() -> UInt32 {
        guard remaining >= 4 else { offset = data.endIndex; return 0 }
        var v: UInt32 = 0
        _ = Swift.withUnsafeMutableBytes(of: &v) { data.copyBytes(to: $0, from: offset..<offset + 4) }
        offset += 4; return UInt32(bigEndian: v)
    }
    mutating func u64() -> UInt64 {
        guard remaining >= 8 else { offset = data.endIndex; return 0 }
        var v: UInt64 = 0
        _ = Swift.withUnsafeMutableBytes(of: &v) { data.copyBytes(to: $0, from: offset..<offset + 8) }
        offset += 8; return UInt64(bigEndian: v)
    }
    mutating func f32() -> Float { Float(bitPattern: u32()) }
    mutating func skip(_ n: Int) { offset = Swift.min(data.endIndex, offset + n) }
}
