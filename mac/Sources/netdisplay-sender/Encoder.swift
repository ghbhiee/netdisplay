import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

/// VideoToolbox H.264 encoder. Input: NV12/BGRA CVPixelBuffer. Output (via
/// `onEncoded`): a complete access unit in Annex-B, with SPS/PPS prepended on
/// keyframes, plus pts (µs) and keyframe flag.
final class Encoder {
    private var session: VTCompressionSession?
    private let width: Int
    private let height: Int
    private let bitrate: Int
    private let fps: Int
    private let prioritizeQuality: Bool
    private let startCode: [UInt8] = [0, 0, 0, 1]

    /// Called on VideoToolbox's callback thread for each encoded frame.
    var onEncoded: ((_ ptsUs: UInt64, _ isKeyframe: Bool, _ annexB: Data) -> Void)?

    private var forceKeyframe = false
    private let lock = NSLock()

    init?(width: Int, height: Int, bitrateBps: Int, fps: Int = 60, prioritizeQuality: Bool = false) {
        self.width = width
        self.height = height
        self.bitrate = bitrateBps
        self.fps = fps
        self.prioritizeQuality = prioritizeQuality
        guard setup() else { return nil }
    }

    deinit {
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
            codecType: kCMVideoCodecType_H264,
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
        set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel)
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
        Log.info("encoder ready: \(width)x\(height) H.264 \(bitrate / 1_000_000)Mbps @\(fps) quality=\(prioritizeQuality)")
        return true
    }

    func requestKeyframe() {
        lock.lock(); forceKeyframe = true; lock.unlock()
    }

    func encode(pixelBuffer: CVPixelBuffer, pts: CMTime) {
        guard let session else { return }
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
        // On keyframes, prepend SPS/PPS (they live in the format description).
        if isKeyframe(sample), let fmt = CMSampleBufferGetFormatDescription(sample) {
            for i in 0..<2 { // index 0 = SPS, 1 = PPS
                var psPtr: UnsafePointer<UInt8>?
                var psLen = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                        fmt, parameterSetIndex: i,
                        parameterSetPointerOut: &psPtr,
                        parameterSetSizeOut: &psLen,
                        parameterSetCountOut: nil,
                        nalUnitHeaderLengthOut: nil) == noErr,
                   let psPtr {
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
