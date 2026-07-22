import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

/// Receiver-side video decoder (the symmetric app's Mac half). Feeds it complete
/// Annex-B access units (as produced by our Encoder / Windows Sender): parameter
/// sets on keyframes (H.264 SPS/PPS, HEVC VPS/SPS/PPS) followed by VCL NALs. It
/// (re)builds the format description + VTDecompressionSession when parameter sets
/// arrive, then emits decoded CVImageBuffers through `onDecoded`.
final class Decoder {
    private var session: VTDecompressionSession?
    private var formatDesc: CMVideoFormatDescription?
    private let codec: VideoCodec

    // Latest parameter sets seen (H.264: [SPS, PPS]; HEVC: [VPS, SPS, PPS]).
    private var parameterSets: [Data] = []

    /// Called for each decoded frame with the image buffer + its pts.
    var onDecoded: ((_ image: CVImageBuffer, _ pts: CMTime) -> Void)?
    /// Called when a decode fails hard (receiver should request a keyframe).
    var onDecodeError: ((OSStatus) -> Void)?

    // In-flight async decodes, for receiver-side backpressure.
    private let pendingLock = NSLock()
    private var _pending = 0
    /// Number of frames submitted to VT but not yet returned by its async handler.
    var pending: Int { pendingLock.lock(); defer { pendingLock.unlock() }; return _pending }
    private func pendingDelta(_ d: Int) { pendingLock.lock(); _pending += d; pendingLock.unlock() }

    init(codec: VideoCodec) { self.codec = codec }

    deinit {
        if let session { VTDecompressionSessionInvalidate(session) }
    }

    /// Feed one complete access unit. `ptsUs` is microseconds (as carried on the wire).
    func decode(annexB: Data, ptsUs: UInt64) {
        let nals = Decoder.splitAnnexB(annexB)
        guard !nals.isEmpty else { return }

        var vcl: [Data] = []
        var gotNewParamSets = false
        for nal in nals {
            switch classify(nal) {
            case .parameterSet(let slot):
                setParameterSet(nal, slot: slot)
                gotNewParamSets = true
            case .vcl:
                vcl.append(nal)
            case .ignore:
                break
            }
        }
        if gotNewParamSets { rebuildSessionIfReady() }
        guard !vcl.isEmpty, let fmt = formatDesc, let session else { return }

        // Concatenate VCL NALs as AVCC (4-byte big-endian length prefix).
        var avcc = Data()
        for nal in vcl {
            var len = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &len) { avcc.append(contentsOf: $0) }
            avcc.append(nal)
        }
        guard let sample = makeSampleBuffer(avcc: avcc, fmt: fmt, ptsUs: ptsUs) else { return }

        pendingDelta(1)
        let status = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sample,
            flags: [._EnableAsynchronousDecompression],
            infoFlagsOut: nil
        ) { [weak self] status, _, image, pts, _ in
            guard let self else { return }
            self.pendingDelta(-1)   // async handler fired → one less in flight
            if status == noErr, let image {
                self.onDecoded?(image, pts)
            } else if status != noErr {
                self.onDecodeError?(status)
            }
        }
        if status != noErr { pendingDelta(-1); onDecodeError?(status) } // handler won't fire
    }

    // MARK: Parameter sets → format description → session

    private enum NalKind { case parameterSet(Int), vcl, ignore }

    /// Classify a NAL by header. Returns the parameter-set slot index so we keep
    /// them in the order the format-description API expects.
    private func classify(_ nal: Data) -> NalKind {
        guard let first = nal.first else { return .ignore }
        if codec.isHEVC {
            let t = (first >> 1) & 0x3F
            switch t {
            case 32: return .parameterSet(0) // VPS
            case 33: return .parameterSet(1) // SPS
            case 34: return .parameterSet(2) // PPS
            case 0...31: return .vcl          // VCL NAL types
            default: return .ignore           // SEI(39/40), AUD(35), etc.
            }
        } else {
            let t = first & 0x1F
            switch t {
            case 7: return .parameterSet(0) // SPS
            case 8: return .parameterSet(1) // PPS
            case 1, 5: return .vcl           // non-IDR / IDR slice
            default: return .ignore          // AUD(9), SEI(6), etc.
            }
        }
    }

    private func setParameterSet(_ nal: Data, slot: Int) {
        let need = codec.isHEVC ? 3 : 2
        if parameterSets.count != need { parameterSets = Array(repeating: Data(), count: need) }
        if slot < need { parameterSets[slot] = nal }
    }

    /// (Re)build the CMFormatDescription + decompression session once all needed
    /// parameter sets are present. A changed parameter set invalidates the old session.
    private func rebuildSessionIfReady() {
        let need = codec.isHEVC ? 3 : 2
        guard parameterSets.count == need, parameterSets.allSatisfy({ !$0.isEmpty }) else { return }

        var fmt: CMVideoFormatDescription?
        let status = parameterSets.withPointers { ptrs, sizes -> OSStatus in
            if codec.isHEVC {
                return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: need,
                    parameterSetPointers: ptrs, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &fmt)
            } else {
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: need,
                    parameterSetPointers: ptrs, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &fmt)
            }
        }
        guard status == noErr, let fmt else {
            Log.error("decoder: format description create failed: \(status)"); return
        }
        // Skip rebuild if dimensions/extensions unchanged and session still valid.
        if let existing = formatDesc, let s = session,
           CMFormatDescriptionEqual(existing, otherFormatDescription: fmt),
           VTDecompressionSessionCanAcceptFormatDescription(s, formatDescription: fmt) {
            return
        }
        if let s = session { VTDecompressionSessionInvalidate(s); session = nil }
        formatDesc = fmt

        // Decode to NV12/BGRA-friendly output; nil attrs lets VT pick.
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey: true
        ]
        var newSession: VTDecompressionSession?
        let s2 = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: fmt,
            decoderSpecification: nil, imageBufferAttributes: attrs as CFDictionary,
            outputCallback: nil, decompressionSessionOut: &newSession)
        guard s2 == noErr, let newSession else {
            Log.error("decoder: session create failed: \(s2)"); return
        }
        session = newSession
        let dims = CMVideoFormatDescriptionGetDimensions(fmt)
        Log.info("decoder ready: \(codec.wire) \(dims.width)x\(dims.height)")
    }

    private func makeSampleBuffer(avcc: Data, fmt: CMVideoFormatDescription, ptsUs: UInt64) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        let data = avcc
        var mutable = data
        let status = mutable.withUnsafeMutableBytes { raw -> OSStatus in
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: raw.baseAddress,
                blockLength: data.count, blockAllocator: kCFAllocatorNull,
                customBlockSource: nil, offsetToData: 0, dataLength: data.count,
                flags: 0, blockBufferOut: &block)
        }
        guard status == kCMBlockBufferNoErr, let block else { return nil }
        // Copy bytes into a buffer the block owns (raw pointer above is transient).
        var owned: CMBlockBuffer?
        guard CMBlockBufferCreateContiguous(
            allocator: kCFAllocatorDefault, sourceBuffer: block, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: data.count,
            flags: kCMBlockBufferAlwaysCopyDataFlag, blockBufferOut: &owned) == kCMBlockBufferNoErr,
            let owned else { return nil }

        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: CMTimeValue(ptsUs), timescale: 1_000_000),
            decodeTimeStamp: .invalid)
        var sizes = [data.count]
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: owned, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: fmt,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sizes,
            sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }

    // MARK: Annex-B splitting

    /// Split an Annex-B buffer into raw NAL payloads (start codes stripped).
    static func splitAnnexB(_ data: Data) -> [Data] {
        var nals: [Data] = []
        let n = data.count
        var i = 0
        var nalStart = -1
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let p = raw.bindMemory(to: UInt8.self)
            func isStart(_ idx: Int) -> Int {
                // returns start-code length (3 or 4) at idx, or 0
                if idx + 3 <= n, p[idx] == 0, p[idx+1] == 0, p[idx+2] == 1 { return 3 }
                if idx + 4 <= n, p[idx] == 0, p[idx+1] == 0, p[idx+2] == 0, p[idx+3] == 1 { return 4 }
                return 0
            }
            while i < n {
                let sc = isStart(i)
                if sc > 0 {
                    if nalStart >= 0 && i > nalStart {
                        nals.append(data.subdata(in: nalStart..<i))
                    }
                    i += sc
                    nalStart = i
                } else {
                    i += 1
                }
            }
            if nalStart >= 0 && nalStart < n {
                nals.append(data.subdata(in: nalStart..<n))
            }
        }
        return nals
    }
}

private extension Array where Element == Data {
    /// Expose the parameter-set byte pointers + sizes for the format-description API.
    func withPointers<R>(_ body: (UnsafePointer<UnsafePointer<UInt8>>, UnsafePointer<Int>) -> R) -> R {
        var ptrs: [UnsafePointer<UInt8>] = []
        var sizes: [Int] = []
        // Keep the Data buffers pinned for the duration of the call.
        func recurse(_ idx: Int) -> R {
            if idx == count {
                return ptrs.withUnsafeBufferPointer { pb in
                    sizes.withUnsafeBufferPointer { sb in
                        body(pb.baseAddress!, sb.baseAddress!)
                    }
                }
            }
            return self[idx].withUnsafeBytes { raw -> R in
                ptrs.append(raw.bindMemory(to: UInt8.self).baseAddress!)
                sizes.append(self[idx].count)
                return recurse(idx + 1)
            }
        }
        return recurse(0)
    }
}
