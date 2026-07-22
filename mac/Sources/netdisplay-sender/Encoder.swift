import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

/// Wire codec (matches protocol `codec` values). hevc422 (4:2:2 10-bit) needs a
/// 4:2:2 input pixel format — added in a later step; hevc = HEVC Main 4:2:0.
enum VideoCodec: String {
    case h264, hevc, hevc422
    var isHEVC: Bool { self != .h264 }
    var cmType: CMVideoCodecType { isHEVC ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264 }
    var wire: String { rawValue }
    /// VT profile: H.264 High, HEVC Main (4:2:0 8-bit), or HEVC Rext Main 4:2:2 10-bit.
    var profileLevel: CFString {
        switch self {
        case .h264:    return kVTProfileLevel_H264_High_AutoLevel
        case .hevc:    return kVTProfileLevel_HEVC_Main_AutoLevel
        case .hevc422: return kVTProfileLevel_HEVC_Main42210_AutoLevel
        }
    }
    /// Capture pixel format the encoder needs. 4:2:2 requires a full-chroma
    /// source (BGRA); VT subsamples to 4:2:2 10-bit. 4:2:0 paths use NV12.
    var captureFormat: OSType {
        self == .hevc422 ? kCVPixelFormatType_32BGRA
                         : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    }
}

/// VideoToolbox H.264/HEVC encoder. Input: NV12/BGRA CVPixelBuffer. Output (via
/// `onEncoded`): a complete access unit in Annex-B, with parameter sets
/// (H.264 SPS/PPS, HEVC VPS/SPS/PPS) prepended on keyframes, plus pts (µs) + key flag.
final class Encoder {
    private var session: VTCompressionSession?
    private let width: Int
    private let height: Int
    private let bitrate: Int
    private let fps: Int
    private let prioritizeQuality: Bool
    private let codec: VideoCodec
    private let startCode: [UInt8] = [0, 0, 0, 1]

    // hevc422 only: convert the full-chroma BGRA capture into a 10-bit 4:2:2
    // buffer (p422) so VideoToolbox actually emits Main 4:2:2 10-bit. Without
    // this, feeding BGRA makes VT default to 4:2:0.
    private var transferSession: VTPixelTransferSession?
    private var chromaPool: CVPixelBufferPool?

    /// Called on VideoToolbox's callback thread for each encoded frame.
    var onEncoded: ((_ ptsUs: UInt64, _ isKeyframe: Bool, _ annexB: Data) -> Void)?

    private var forceKeyframe = false
    private let lock = NSLock()

    init?(width: Int, height: Int, bitrateBps: Int, fps: Int = 60, prioritizeQuality: Bool = false,
          codec: VideoCodec = .h264) {
        self.width = width
        self.height = height
        self.bitrate = bitrateBps
        self.fps = fps
        self.prioritizeQuality = prioritizeQuality
        self.codec = codec
        guard setup() else { return nil }
    }

    deinit {
        if let transferSession { VTPixelTransferSessionInvalidate(transferSession) }
        if let session {
            VTCompressionSessionInvalidate(session)
        }
    }

    private func setup() -> Bool {
        let spec: CFDictionary = [
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue!
        ] as CFDictionary

        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(width),
            height: Int32(height),
            codecType: codec.cmType,
            encoderSpecification: spec,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        guard status == noErr, let session else {
            Log.error("VTCompressionSessionCreate failed: \(status)")
            return false
        }

        func set(_ key: CFString, _ value: CFTypeRef) {
            VTSessionSetProperty(session, key: key, value: value)
        }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_ProfileLevel, codec.profileLevel)
        // Keyframe every 2s (protocol §3), plus we force one on demand.
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 2 as CFNumber)
        set(kVTCompressionPropertyKey_MaxFrameDelayCount, 0 as CFNumber)
        set(kVTCompressionPropertyKey_AverageBitRate, bitrate as CFNumber)
        // Cap the peak so a busy frame can't blow the (relay) budget and mush everything.
        set(kVTCompressionPropertyKey_DataRateLimits, [bitrate * 3 / 2 / 8, 1] as CFArray)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, fps as CFNumber)
        // Speed-over-quality trades sharpness for latency; off = sharper text at same bitrate.
        set(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality,
            prioritizeQuality ? kCFBooleanFalse : kCFBooleanTrue)
        VTCompressionSessionPrepareToEncodeFrames(session)
        if codec == .hevc422 && !setupChromaTransfer() {
            Log.error("hevc422: chroma transfer setup failed"); return false
        }
        Log.info("encoder ready: \(width)x\(height) \(codec.wire) \(bitrate / 1_000_000)Mbps @\(fps) quality=\(prioritizeQuality)")
        return true
    }

    /// Build the BGRA→p422 (10-bit 4:2:2) transfer session + destination pool.
    private func setupChromaTransfer() -> Bool {
        var ts: VTPixelTransferSession?
        guard VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &ts) == noErr,
              let ts else { return false }
        VTSessionSetProperty(ts, key: kVTPixelTransferPropertyKey_RealTime, value: kCFBooleanTrue)
        transferSession = ts

        let poolAttrs = [kCVPixelBufferPoolMinimumBufferCountKey: 3] as CFDictionary
        let bufAttrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, // 'p422'
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(nil, poolAttrs, bufAttrs as CFDictionary, &pool) == kCVReturnSuccess,
              let pool else { return false }
        chromaPool = pool
        return true
    }

    /// For hevc422: transfer the BGRA source into a 10-bit 4:2:2 buffer VT will
    /// keep as 4:2:2. Returns the incoming buffer unchanged for other codecs.
    private func chromaConverted(_ src: CVPixelBuffer) -> CVPixelBuffer? {
        guard codec == .hevc422, let ts = transferSession, let pool = chromaPool else { return src }
        var dst: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &dst) == kCVReturnSuccess, let dst else { return nil }
        guard VTPixelTransferSessionTransferImage(ts, from: src, to: dst) == noErr else { return nil }
        return dst
    }

    func requestKeyframe() {
        lock.lock(); forceKeyframe = true; lock.unlock()
    }

    func encode(pixelBuffer: CVPixelBuffer, pts: CMTime) {
        guard let session else { return }
        guard let pixelBuffer = chromaConverted(pixelBuffer) else { return } // hevc422: BGRA→p422
        lock.lock()
        let force = forceKeyframe
        forceKeyframe = false
        lock.unlock()

        var props: CFDictionary?
        if force {
            props = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue!] as CFDictionary
        }

        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: props,
            infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            guard let self, status == noErr, let sampleBuffer,
                  CMSampleBufferDataIsReady(sampleBuffer) else { return }
            self.handleEncoded(sampleBuffer, pts: pts)
        }
    }

    private func handleEncoded(_ sample: CMSampleBuffer, pts: CMTime) {
        guard let annexB = annexB(from: sample) else { return }
        let key = isKeyframe(sample)
        let ptsUs = UInt64(max(0, CMTimeGetSeconds(pts) * 1_000_000))
        onEncoded?(ptsUs, key, annexB)
    }

    private func annexB(from sample: CMSampleBuffer) -> Data? {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        var len = 0, total = 0
        var ptr: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0,
                lengthAtOffsetOut: &len, totalLengthOut: &total,
                dataPointerOut: &ptr) == noErr, let ptr else { return nil }

        var out = Data(capacity: total + 128)
        // On keyframes, prepend parameter sets (H.264: SPS,PPS; HEVC: VPS,SPS,PPS).
        if isKeyframe(sample), let fmt = CMSampleBufferGetFormatDescription(sample) {
            let count = codec.isHEVC ? 3 : 2
            for i in 0..<count {
                var psPtr: UnsafePointer<UInt8>?
                var psLen = 0
                let ok: OSStatus = codec.isHEVC
                    ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                        fmt, parameterSetIndex: i, parameterSetPointerOut: &psPtr,
                        parameterSetSizeOut: &psLen, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                    : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                        fmt, parameterSetIndex: i, parameterSetPointerOut: &psPtr,
                        parameterSetSizeOut: &psLen, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                if ok == noErr, let psPtr {
                    out.append(contentsOf: startCode)
                    out.append(Data(bytes: psPtr, count: psLen))
                }
            }
        }
        // Convert AVCC (4-byte length-prefixed NALUs) to Annex-B start codes.
        let raw = UnsafeRawPointer(ptr)
        var offset = 0
        while offset + 4 <= total {
            var nalLen: UInt32 = 0
            memcpy(&nalLen, raw + offset, 4)
            nalLen = CFSwapInt32BigToHost(nalLen)
            offset += 4
            guard offset + Int(nalLen) <= total else { break }
            out.append(contentsOf: startCode)
            out.append(Data(bytes: raw + offset, count: Int(nalLen)))
            offset += Int(nalLen)
        }
        return out
    }

    private func isKeyframe(_ sample: CMSampleBuffer) -> Bool {
        guard let arr = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false),
              CFArrayGetCount(arr) > 0 else { return true }
        let dict = unsafeBitCast(CFArrayGetValueAtIndex(arr, 0), to: CFDictionary.self)
        let notSyncKey = Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque()
        var value: UnsafeRawPointer?
        let present = CFDictionaryGetValueIfPresent(dict, notSyncKey, &value)
        if present, let value {
            let notSync = unsafeBitCast(value, to: CFBoolean.self)
            return !CFBooleanGetValue(notSync)
        }
        return true // no NotSync attachment → sync frame
    }
}
