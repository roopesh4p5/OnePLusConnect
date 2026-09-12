import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

enum EncoderError: LocalizedError {
    case sessionCreate(OSStatus)
    case encode(OSStatus)

    var errorDescription: String? {
        switch self {
        case .sessionCreate(let s): return "Mac video encoder could not start (VideoToolbox \(s))."
        case .encode(let s): return "Video encode failed (VideoToolbox \(s))."
        }
    }
}

/// Wire codec. The value is what goes into SESSION_CONFIG.codec and what the tablet matches on.
enum StreamCodec: String {
    case h264
    case hevc

    var title: String { self == .hevc ? "HEVC" : "H.264" }
    var cmCodecType: CMVideoCodecType { self == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264 }
}

struct EncodedFrame {
    /// Annex B access unit (start-code delimited NAL units, no parameter sets).
    let data: Data
    let isKeyframe: Bool
    /// Annex B parameter sets (SPS+PPS for H.264, VPS+SPS+PPS for HEVC), present on keyframes.
    let parameterSets: Data?
    let presentationTime: CMTime
    let captureTimestampMicros: UInt64
    let encodeLatencyMs: Double
}

/// VideoToolbox encoder tuned for low latency: realtime, no B-frames, LL rate control.
/// Handles both H.264 and HEVC; HEVC is what makes a Wi-Fi link look like the cable, because it
/// needs roughly half the bits for the same picture.
final class VideoEncoder {
    let codec: StreamCodec
    let width: Int
    let height: Int
    let fps: Int
    private(set) var bitrate: Int

    var onFrame: ((EncodedFrame) -> Void)?

    private var session: VTCompressionSession?
    private let lock = NSLock()
    private var forceKey = false
    private var frameCount: Int64 = 0
    private var lastParameterSets: Data?
    private var lastFormatDescription: CMFormatDescription?

    init(codec: StreamCodec, width: Int, height: Int, fps: Int, bitrate: Int) throws {
        self.codec = codec
        self.width = width
        self.height = height
        self.fps = fps
        self.bitrate = bitrate

        let spec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true,
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
        ]
        let sourceAttrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
        ]
        var s: VTCompressionSession?
        var status = VTCompressionSessionCreate(allocator: nil,
                                                width: Int32(width), height: Int32(height),
                                                codecType: codec.cmCodecType,
                                                encoderSpecification: spec as CFDictionary,
                                                imageBufferAttributes: sourceAttrs as CFDictionary,
                                                compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil,
                                                compressionSessionOut: &s)
        if status != noErr || s == nil {
            // Retry without low-latency mode (older encoders).
            Log.shared.warn("Low-latency encoder unavailable (\(status)); falling back to standard mode.")
            let fallbackSpec: [CFString: Any] = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true]
            status = VTCompressionSessionCreate(allocator: nil,
                                                width: Int32(width), height: Int32(height),
                                                codecType: codec.cmCodecType,
                                                encoderSpecification: fallbackSpec as CFDictionary,
                                                imageBufferAttributes: sourceAttrs as CFDictionary,
                                                compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil,
                                                compressionSessionOut: &s)
        }
        guard status == noErr, let session = s else { throw EncoderError.sessionCreate(status) }
        self.session = session

        func set(_ key: CFString, _ value: Any) {
            let r = VTSessionSetProperty(session, key: key, value: value as CFTypeRef)
            if r != noErr { Log.shared.debug("Encoder property \(key) not applied (\(r))") }
        }
        set(kVTCompressionPropertyKey_RealTime, true)
        set(kVTCompressionPropertyKey_AllowFrameReordering, false)
        set(kVTCompressionPropertyKey_ProfileLevel, codec == .hevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel)
        set(kVTCompressionPropertyKey_AverageBitRate, bitrate)
        // Peak limit 1.5x the average per second: keyframes and busy frames get headroom instead of being smeared.
        set(kVTCompressionPropertyKey_DataRateLimits, [bitrate * 3 / 16, 1] as [Int])
        set(kVTCompressionPropertyKey_ExpectedFrameRate, fps)
        // Long GOP: a keyframe every 2 s at this resolution costs sharpness; the tablet requests one on demand anyway.
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, fps * 10)
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 10)
        set(kVTCompressionPropertyKey_MaximizePowerEfficiency, false)
        set(kVTCompressionPropertyKey_MaxFrameDelayCount, 0)
        if codec == .h264 { set(kVTCompressionPropertyKey_H264EntropyMode, kVTH264EntropyMode_CABAC) }
        VTCompressionSessionPrepareToEncodeFrames(session)
        Log.shared.info("Encoder ready: \(codec.title) \(width)x\(height) @ \(fps) fps, \(bitrate / 1_000_000) Mbps")
    }

    /// Whether VideoToolbox on this Mac can encode `codec` at all. Probed once per codec, because the
    /// answer decides what we promise the tablet in SESSION_CONFIG (before any frame is encoded).
    private static var availability: [String: Bool] = [:]
    private static let availabilityLock = NSLock()
    static func isAvailable(_ codec: StreamCodec) -> Bool {
        availabilityLock.lock(); defer { availabilityLock.unlock() }
        if let cached = availability[codec.rawValue] { return cached }
        var session: VTCompressionSession?
        let spec: [CFString: Any] = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true]
        let status = VTCompressionSessionCreate(allocator: nil, width: 1920, height: 1080,
                                                codecType: codec.cmCodecType,
                                                encoderSpecification: spec as CFDictionary,
                                                imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        let ok = status == noErr && session != nil
        if let session = session { VTCompressionSessionInvalidate(session) }
        availability[codec.rawValue] = ok
        if !ok { Log.shared.warn("This Mac cannot encode \(codec.title) (VideoToolbox \(status)).") }
        return ok
    }

    func forceKeyframe() {
        lock.lock(); forceKey = true; lock.unlock()
    }

    func setBitrate(_ newBitrate: Int) {
        guard let session = session, newBitrate != bitrate else { return }
        bitrate = newBitrate
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: newBitrate as CFTypeRef)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: [newBitrate * 3 / 16, 1] as CFArray)
        Log.shared.info("Encoder bitrate → \(newBitrate / 1_000_000) Mbps")
    }

    func encode(pixelBuffer: CVPixelBuffer, presentationTime: CMTime, captureTimestampMicros: UInt64) {
        guard let session = session else { return }
        lock.lock()
        let key = forceKey
        forceKey = false
        frameCount += 1
        lock.unlock()

        var props: [CFString: Any] = [:]
        if key { props[kVTEncodeFrameOptionKey_ForceKeyFrame] = true }
        let submitted = Clock.monotonic()
        let duration = CMTime(value: 1, timescale: CMTimeScale(fps))

        let status = VTCompressionSessionEncodeFrame(session,
                                                     imageBuffer: pixelBuffer,
                                                     presentationTimeStamp: presentationTime,
                                                     duration: duration,
                                                     frameProperties: props.isEmpty ? nil : props as CFDictionary,
                                                     infoFlagsOut: nil) { [weak self] status, _, sampleBuffer in
            guard let self = self else { return }
            guard status == noErr, let sb = sampleBuffer else {
                Log.shared.warn("Encode callback error \(status)")
                return
            }
            self.handleOutput(sb, submitted: submitted, captureTimestampMicros: captureTimestampMicros)
        }
        if status != noErr {
            Log.shared.warn("VTCompressionSessionEncodeFrame failed: \(status)")
        }
    }

    private func handleOutput(_ sb: CMSampleBuffer, submitted: Double, captureTimestampMicros: UInt64) {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sb) else { return }

        var isKeyframe = true
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]],
           let first = attachments.first,
           let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool {
            isKeyframe = !notSync
        }

        var parameterSets: Data?
        var nalLengthSize = 4
        if let fmt = CMSampleBufferGetFormatDescription(sb) {
            if isKeyframe || lastParameterSets == nil || lastFormatDescription == nil || !CMFormatDescriptionEqual(fmt, otherFormatDescription: lastFormatDescription) {
                parameterSets = VideoEncoder.extractParameterSets(fmt, codec: codec, nalLengthSize: &nalLengthSize)
                lastParameterSets = parameterSets
                lastFormatDescription = fmt
            } else {
                var tmp: Int32 = 0
                if codec == .hevc {
                    _ = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fmt, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: nil, nalUnitHeaderLengthOut: &tmp)
                } else {
                    _ = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: nil, nalUnitHeaderLengthOut: &tmp)
                }
                if tmp > 0 { nalLengthSize = Int(tmp) }
            }
        }
        if isKeyframe && parameterSets == nil { parameterSets = lastParameterSets }

        let total = CMBlockBufferGetDataLength(dataBuffer)
        var raw = Data(count: total)
        let copyStatus = raw.withUnsafeMutableBytes { ptr -> OSStatus in
            guard let base = ptr.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(dataBuffer, atOffset: 0, dataLength: total, destination: base)
        }
        guard copyStatus == noErr else { return }

        let annexB = VideoEncoder.avccToAnnexB(raw, lengthSize: nalLengthSize)
        let frame = EncodedFrame(data: annexB,
                                 isKeyframe: isKeyframe,
                                 parameterSets: isKeyframe ? parameterSets : nil,
                                 presentationTime: CMSampleBufferGetPresentationTimeStamp(sb),
                                 captureTimestampMicros: captureTimestampMicros,
                                 encodeLatencyMs: (Clock.monotonic() - submitted) * 1000)
        onFrame?(frame)
    }

    private static let startCode = Data([0, 0, 0, 1])

    /// Annex B parameter sets: SPS+PPS (H.264) or VPS+SPS+PPS (HEVC), in the order VideoToolbox reports them.
    static func extractParameterSets(_ fmt: CMFormatDescription, codec: StreamCodec, nalLengthSize: inout Int) -> Data? {
        func describe(_ index: Int, _ ptr: UnsafeMutablePointer<UnsafePointer<UInt8>?>?, _ size: UnsafeMutablePointer<Int>?,
                      _ count: UnsafeMutablePointer<Int>?, _ headerLen: UnsafeMutablePointer<Int32>?) -> OSStatus {
            codec == .hevc
                ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fmt, parameterSetIndex: index, parameterSetPointerOut: ptr, parameterSetSizeOut: size, parameterSetCountOut: count, nalUnitHeaderLengthOut: headerLen)
                : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: index, parameterSetPointerOut: ptr, parameterSetSizeOut: size, parameterSetCountOut: count, nalUnitHeaderLengthOut: headerLen)
        }
        var count = 0
        var headerLen: Int32 = 4
        let s = describe(0, nil, nil, &count, &headerLen)
        guard s == noErr, count > 0 else { return nil }
        nalLengthSize = Int(headerLen)
        var out = Data()
        for i in 0..<count {
            var ptr: UnsafePointer<UInt8>?
            var size = 0
            let r = describe(i, &ptr, &size, nil, nil)
            guard r == noErr, let p = ptr else { continue }
            out.append(startCode)
            out.append(p, count: size)
        }
        return out
    }

    /// Converts length-prefixed NAL units (AVCC) into Annex B start-code framing.
    static func avccToAnnexB(_ avcc: Data, lengthSize: Int) -> Data {
        var out = Data(capacity: avcc.count + 64)
        var offset = 0
        let n = avcc.count
        while offset + lengthSize <= n {
            var length = 0
            for i in 0..<lengthSize { length = (length << 8) | Int(avcc[offset + i]) }
            offset += lengthSize
            guard length > 0, offset + length <= n else { break }
            out.append(startCode)
            out.append(avcc.subdata(in: offset..<offset + length))
            offset += length
        }
        return out
    }

    func invalidate() {
        guard let s = session else { return }
        session = nil
        VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(s)
        Log.shared.info("Encoder stopped")
    }

    deinit { invalidate() }
}
