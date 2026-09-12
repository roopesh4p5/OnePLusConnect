import Foundation

/// JSON control messages carried in packet payloads.

enum SessionMode: String, Codable, CaseIterable {
    case mirror
    case extend

    var title: String { self == .mirror ? "Mirror" : "Extended" }
}

enum Orientation: String, Codable {
    case portrait
    case landscape
    case reversePortrait = "reverse_portrait"
    case reverseLandscape = "reverse_landscape"

    var isPortrait: Bool { self == .portrait || self == .reversePortrait }
}

struct HelloMessage: Codable {
    var protocolVersion: Int
    var appVersion: String
    var deviceId: String
    var hostName: String
    var capabilities: [String]
    /// "usb" or "wifi" — informational, lets the tablet label the link (optional for old peers).
    var transport: String?
}

struct HelloAckMessage: Codable {
    var protocolVersion: Int
    var appVersion: String
    var deviceModel: String
    var manufacturer: String?
    var androidVersion: String?
    var displayWidth: Int
    var displayHeight: Int
    var refreshRates: [Double]
    var codecs: [String]
    var touch: Bool
    var multitouch: Bool
    var stylus: Bool
    var orientation: Orientation
    var densityDpi: Int?
    /// Highest frame rate the tablet's H.264 decoder supports at its native panel size (0/absent = unknown).
    var maxFpsAtNative: Int?
    /// Same ceiling for the HEVC decoder; often lower than H.264 (absent = tablet predates HEVC support).
    var maxFpsAtNativeHevc: Int?
}

struct SessionConfigMessage: Codable {
    var sessionId: UInt32
    var mode: SessionMode
    var width: Int
    var height: Int
    var fps: Int
    var bitrate: Int
    var codec: String
    var colorFormat: String
    var orientation: Orientation
}

struct SessionReadyMessage: Codable {
    var sessionId: UInt32
    var ok: Bool
    var error: String?
}

struct SessionStopMessage: Codable {
    var reason: String
}

struct OrientationMessage: Codable {
    var orientation: Orientation
    var displayWidth: Int?
    var displayHeight: Int?
}

struct PingMessage: Codable {
    var t1: UInt64
}

struct PongMessage: Codable {
    var t1: UInt64
    var t2: UInt64
    var t3: UInt64
}

struct StatsMessage: Codable {
    var fps: Double?
    var decodeLatencyMs: Double?
    var renderedFrames: Int?
    var droppedFrames: Int?
    var queueDepth: Int?
    var battery: Int?
    var thermal: String?
    /// Average (tablet render time - Mac capture timestamp) in ms, raw (not clock-corrected).
    var pipelineLatencyRawMs: Double?
}

struct ErrorMessage: Codable {
    var code: String
    var message: String
}

enum JSONCoding {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    static let decoder = JSONDecoder()

    static func encode<T: Encodable>(_ value: T) -> Data {
        (try? encoder.encode(value)) ?? Data()
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? decoder.decode(type, from: data)
    }
}

extension Packet {
    static func control<T: Encodable>(_ type: PacketType, _ message: T, sessionID: UInt32 = 0) -> Packet {
        Packet(type: type, payload: JSONCoding.encode(message), sessionID: sessionID)
    }
}
