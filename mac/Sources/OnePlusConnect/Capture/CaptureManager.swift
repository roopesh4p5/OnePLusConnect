import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo

enum CaptureError: LocalizedError {
    case permissionDenied
    case displayNotFound(CGDirectDisplayID)

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "One+Connect needs Screen Recording permission."
        case .displayNotFound(let id): return "Display \(id) is not available for capture."
        }
    }
}

/// ScreenCaptureKit wrapper capturing one display at a fixed output size and frame rate.
final class CaptureManager: NSObject, SCStreamOutput, SCStreamDelegate {
    let displayID: CGDirectDisplayID
    let width: Int
    let height: Int
    let fps: Int

    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?
    var onStopped: ((Error?) -> Void)?

    private var stream: SCStream?
    private let outputQueue = DispatchQueue(label: "oneplusconnect.capture", qos: .userInteractive)
    private(set) var framesReceived = 0

    init(displayID: CGDirectDisplayID, width: Int, height: Int, fps: Int) {
        self.displayID = displayID
        self.width = width
        self.height = height
        self.fps = fps
    }

    static func hasPermission() -> Bool { CGPreflightScreenCaptureAccess() }
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    /// Waits until ScreenCaptureKit lists the display (virtual displays take a moment to appear).
    static func waitForDisplay(_ id: CGDirectDisplayID, timeout: TimeInterval) async -> SCDisplay? {
        let start = Clock.monotonic()
        while Clock.monotonic() - start < timeout {
            if let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false),
               let d = content.displays.first(where: { $0.displayID == id }) {
                return d
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return nil
    }

    func start() async throws {
        guard CaptureManager.hasPermission() else { throw CaptureError.permissionDenied }
        guard let display = await CaptureManager.waitForDisplay(displayID, timeout: 6) else {
            throw CaptureError.displayNotFound(displayID)
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.queueDepth = 3
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.showsCursor = true
        config.capturesAudio = false
        config.colorSpaceName = CGColorSpace.sRGB
        config.scalesToFit = false
        config.captureResolution = .best

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
        try await stream.startCapture()
        self.stream = stream
        Log.shared.info("Capture started: display \(displayID) → \(width)x\(height) @ \(fps)")
    }

    func stop() async {
        guard let s = stream else { return }
        stream = nil
        do { try await s.stopCapture() } catch { Log.shared.debug("stopCapture: \(error.localizedDescription)") }
        Log.shared.info("Capture stopped (\(framesReceived) frames)")
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let first = attachments.first,
              let statusRaw = first[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw),
              status == .complete else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        framesReceived += 1
        onFrame?(pixelBuffer, CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.shared.error("Capture stopped with error: \(error.localizedDescription)")
        self.stream = nil
        onStopped?(error)
    }
}
