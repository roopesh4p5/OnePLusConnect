import Foundation

/// Binary TOUCH payload:
///   u8 action, u8 actionIndex, u8 pointerCount, u8 flags
///   per pointer (16 bytes): u8 id, u8 toolType, u16 reserved, f32 x, f32 y, f32 pressure
/// Coordinates are normalized 0...1 relative to the video content rectangle on the tablet.
enum TouchAction: UInt8 {
    case down = 0
    case move = 1
    case up = 2
    case pointerDown = 3
    case pointerUp = 4
    case cancel = 5
}

enum TouchTool: UInt8 {
    case finger = 0
    case stylus = 1
    case unknown = 255
}

struct TouchPointer {
    var id: UInt8
    var tool: TouchTool
    var x: Float
    var y: Float
    var pressure: Float
}

struct TouchFrame {
    var action: TouchAction
    var actionIndex: Int
    var pointers: [TouchPointer]
    var timestampMicros: UInt64

    static func decode(_ data: Data, timestamp: UInt64) -> TouchFrame? {
        guard data.count >= 4 else { return nil }
        var r = BinaryReader(data)
        guard let action = TouchAction(rawValue: r.u8()) else { return nil }
        let actionIndex = Int(r.u8())
        let count = Int(r.u8())
        _ = r.u8()
        guard data.count >= 4 + count * 16 else { return nil }
        var pointers: [TouchPointer] = []
        pointers.reserveCapacity(count)
        for _ in 0..<count {
            let id = r.u8()
            let tool = TouchTool(rawValue: r.u8()) ?? .unknown
            _ = r.u16()
            let x = r.f32()
            let y = r.f32()
            let p = r.f32()
            pointers.append(TouchPointer(id: id, tool: tool, x: x, y: y, pressure: p))
        }
        return TouchFrame(action: action, actionIndex: actionIndex, pointers: pointers, timestampMicros: timestamp)
    }
}
