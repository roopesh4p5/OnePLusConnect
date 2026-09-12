import Foundation
import CoreGraphics
import CGVirtualDisplayShim

struct VirtualDisplayMode: Equatable {
    var width: Int
    var height: Int
    var refreshRate: Double
}

struct VirtualDisplayConfig {
    var name: String = "One+Connect"
    /// Panel pixel size (drives maxPixels and physical size).
    var maxWidth: Int
    var maxHeight: Int
    var modes: [VirtualDisplayMode]
    var hiDPI: Bool
    var diagonalInches: Double = 12.1
}

enum DisplayBackendError: LocalizedError {
    case unavailable
    case createFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: return "Virtual display support is not available on this macOS version. Use Mirror mode."
        case .createFailed(let m): return "Could not create the One+Connect display: \(m)"
        }
    }
}

/// Abstraction over how the extended display is created (PRD §80).
/// Today: private CGVirtualDisplay via the ObjC shim. Later: DriverKit.
protocol DisplayBackend: AnyObject {
    var isAvailable: Bool { get }
    var displayID: CGDirectDisplayID? { get }
    func create(_ config: VirtualDisplayConfig) throws -> CGDirectDisplayID
    func applyModes(_ modes: [VirtualDisplayMode], hiDPI: Bool) -> Bool
    func destroy()
}

final class VirtualDisplayBackend: DisplayBackend {
    private var handle: OPCVirtualDisplayHandle?
    private(set) var displayID: CGDirectDisplayID?

    var isAvailable: Bool { OPCVirtualDisplayIsAvailable() }

    func create(_ config: VirtualDisplayConfig) throws -> CGDirectDisplayID {
        guard isAvailable else { throw DisplayBackendError.unavailable }
        destroy()

        // Physical size from the diagonal and aspect ratio.
        let aspect = Double(config.maxWidth) / Double(config.maxHeight)
        let diagMM = config.diagonalInches * 25.4
        let hMM = diagMM / (aspect * aspect + 1).squareRoot()
        let wMM = hMM * aspect

        let widths = config.modes.map { UInt32($0.width) }
        let heights = config.modes.map { UInt32($0.height) }
        let rates = config.modes.map { $0.refreshRate }
        var err: UnsafePointer<CChar>?

        let h = widths.withUnsafeBufferPointer { wp in
            heights.withUnsafeBufferPointer { hp in
                rates.withUnsafeBufferPointer { rp in
                    OPCVirtualDisplayCreate(config.name, UInt32(config.maxWidth), UInt32(config.maxHeight),
                                            wMM, hMM, 0x4F50, wp.baseAddress, hp.baseAddress, rp.baseAddress,
                                            Int32(config.modes.count), config.hiDPI, &err)
                }
            }
        }
        guard let handle = h else {
            let msg = err.map { String(cString: $0) } ?? "unknown error"
            throw DisplayBackendError.createFailed(msg)
        }
        self.handle = handle
        let id = OPCVirtualDisplayGetID(handle)
        guard id != 0 else {
            OPCVirtualDisplayDestroy(handle)
            self.handle = nil
            throw DisplayBackendError.createFailed("display ID unavailable")
        }
        displayID = id
        Log.shared.info("Virtual display created: id=\(id) modes=\(config.modes.map { "\($0.width)x\($0.height)@\(Int($0.refreshRate))" }) hiDPI=\(config.hiDPI)")
        return id
    }

    func applyModes(_ modes: [VirtualDisplayMode], hiDPI: Bool) -> Bool {
        guard let handle = handle else { return false }
        let widths = modes.map { UInt32($0.width) }
        let heights = modes.map { UInt32($0.height) }
        let rates = modes.map { $0.refreshRate }
        return widths.withUnsafeBufferPointer { wp in
            heights.withUnsafeBufferPointer { hp in
                rates.withUnsafeBufferPointer { rp in
                    OPCVirtualDisplayApplyModes(handle, wp.baseAddress, hp.baseAddress, rp.baseAddress, Int32(modes.count), hiDPI)
                }
            }
        }
    }

    func destroy() {
        guard let handle = handle else { return }
        OPCVirtualDisplayDestroy(handle)
        self.handle = nil
        Log.shared.info("Virtual display destroyed (id=\(displayID ?? 0))")
        displayID = nil
    }

    deinit { destroy() }
}

/// Helpers for working with real displays.
enum DisplayInfo {
    static func mainDisplayID() -> CGDirectDisplayID { CGMainDisplayID() }

    /// Pixel dimensions of a display (backing pixels, not points).
    static func pixelSize(of id: CGDirectDisplayID) -> (Int, Int) {
        if let mode = CGDisplayCopyDisplayMode(id) {
            return (mode.pixelWidth, mode.pixelHeight)
        }
        return (Int(CGDisplayPixelsWide(id)), Int(CGDisplayPixelsHigh(id)))
    }

    static func bounds(of id: CGDirectDisplayID) -> CGRect { CGDisplayBounds(id) }
    static func isActive(_ id: CGDirectDisplayID) -> Bool { CGDisplayIsActive(id) != 0 }
}

extension DisplayInfo {
    /// Switches `id` to the mode whose backing store is exactly `pixelWidth`×`pixelHeight`,
    /// preferring a HiDPI (2x) mode when `hiDPI` is set. Returns the applied pixel size, or nil.
    /// macOS picks its own default mode for a virtual display (often a smaller scaled one), which
    /// would be upscaled on capture and again on the tablet; this pins the framebuffer to native.
    @discardableResult
    static func applyMode(_ id: CGDirectDisplayID, pixelWidth: Int, pixelHeight: Int, hiDPI: Bool) -> (Int, Int)? {
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let all = CGDisplayCopyAllDisplayModes(id, opts) as? [CGDisplayMode] else { return nil }
        let exact = all.filter { $0.pixelWidth == pixelWidth && $0.pixelHeight == pixelHeight && $0.isUsableForDesktopGUI() }
        guard !exact.isEmpty else {
            Log.shared.warn("Display \(id) offers no \(pixelWidth)x\(pixelHeight) mode; available: \(all.map { "\($0.pixelWidth)x\($0.pixelHeight)" }.joined(separator: ","))")
            return nil
        }
        let wanted = exact.first { hiDPI ? $0.width < $0.pixelWidth : $0.width == $0.pixelWidth } ?? exact[0]
        if let current = CGDisplayCopyDisplayMode(id), current.pixelWidth == wanted.pixelWidth, current.pixelHeight == wanted.pixelHeight, current.width == wanted.width {
            return (wanted.pixelWidth, wanted.pixelHeight)
        }
        var cfg: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cfg) == .success, let c = cfg else { return nil }
        guard CGConfigureDisplayWithDisplayMode(c, id, wanted, nil) == .success else {
            CGCancelDisplayConfiguration(c)
            return nil
        }
        let r = CGCompleteDisplayConfiguration(c, .forSession)
        guard r == .success else {
            Log.shared.warn("Could not switch display \(id) to \(pixelWidth)x\(pixelHeight): \(r.rawValue)")
            return nil
        }
        Log.shared.info("Display \(id) mode → \(wanted.width)x\(wanted.height) points, \(wanted.pixelWidth)x\(wanted.pixelHeight) pixels @\(Int(wanted.refreshRate))")
        return (wanted.pixelWidth, wanted.pixelHeight)
    }
}
