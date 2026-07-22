import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo

/// What to capture: a whole display (the virtual one) or a single app window.
enum CaptureSource {
    case display(CGDirectDisplayID)
    case window(SCWindow)
}

/// Captures a display or a single window with ScreenCaptureKit and hands each
/// frame's pixel buffer + pts to `onFrame`.
final class Capture: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let source: CaptureSource
    private var pixelWidth: Int
    private var pixelHeight: Int
    private let queue = DispatchQueue(label: "netdisplay.capture", qos: .userInteractive)
    private let pixelFormat: OSType

    var windowID: CGWindowID? {
        if case .window(let w) = source { return w.windowID }
        return nil
    }

    var onFrame: ((_ pixelBuffer: CVPixelBuffer, _ pts: CMTime) -> Void)?
    /// Called when the stream stops with an error (SCK can transiently drop a
    /// virtual display). The owner should attempt a restart.
    var onStoppedWithError: (() -> Void)?

    init(displayID: CGDirectDisplayID, pixelWidth: Int, pixelHeight: Int,
         pixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) {
        self.source = .display(displayID)
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.pixelFormat = pixelFormat
        super.init()
    }

    init(window: SCWindow, pixelWidth: Int, pixelHeight: Int,
         pixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) {
        self.source = .window(window)
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.pixelFormat = pixelFormat
        super.init()
    }

    private func makeFilter() async throws -> SCContentFilter {
        switch source {
        case .display(let displayID):
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            var wantID = displayID
            if ProcessInfo.processInfo.environment["NETDISPLAY_CAPTURE_MAIN"] == "1" {
                wantID = CGMainDisplayID()
                Log.info("capture: DEBUG overriding to main display \(wantID)")
            }
            guard let scDisplay = content.displays.first(where: { $0.displayID == wantID }) else {
                throw NSError(domain: "netdisplay.capture", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "SCDisplay for id \(wantID) not found"])
            }
            return SCContentFilter(display: scDisplay, excludingWindows: [])
        case .window(let window):
            // Single-window capture: content is just this window, even if occluded.
            return SCContentFilter(desktopIndependentWindow: window)
        }
    }

    private func makeConfig() -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = pixelWidth
        config.height = pixelHeight
        if case .window = source {
            config.scalesToFit = true              // keep the window content sharp within the frame
            config.backgroundColor = .clear
        }
        // Ask for 120 timescale so SCK's rate limiter doesn't beat-drop 60Hz frames.
        config.minimumFrameInterval = CMTime(value: 1, timescale: 120)
        config.pixelFormat = pixelFormat // NV12 by default; BGRA for the capture demo
        config.queueDepth = 6
        config.showsCursor = true
        config.colorSpaceName = CGColorSpace.sRGB
        return config
    }

    /// Change the capture size live (window resize-follow). SCK swaps the output
    /// dimensions without restarting the stream.
    func reconfigure(pixelWidth: Int, pixelHeight: Int) async {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        if let stream {
            try? await stream.updateConfiguration(makeConfig())
            Log.info("capture reconfigured → \(pixelWidth)x\(pixelHeight)")
        }
    }

    func start() async throws {
        let filter = try await makeFilter()
        let config = makeConfig()

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        let src: String
        switch source {
        case .display(let id): src = "display \(id)"
        case .window(let w): src = "window '\(w.owningApplication?.applicationName ?? "?")' (\(w.windowID))"
        }
        Log.info("capture started on \(src) @ \(pixelWidth)x\(pixelHeight)")
    }

    func stop() async {
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
    }

    // MARK: SCStreamOutput

    private var rawCount = 0
    private let debugStatus = ProcessInfo.processInfo.environment["NETDISPLAY_STATS"] == "1"

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        rawCount += 1
        var statusRaw = -1
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let first = attachments.first, let s = first[.status] as? Int {
            statusRaw = s
        }
        if debugStatus && (rawCount <= 3 || rawCount % 120 == 0) {
            Log.info("capture cb #\(rawCount): status=\(statusRaw) numSamples=\(CMSampleBufferGetNumSamples(sampleBuffer)) hasImage=\(CMSampleBufferGetImageBuffer(sampleBuffer) != nil)")
        }
        // status: 0=complete, 1=idle, 2=blank, 3=suspended, 4=started, 5=stopped.
        // Only complete frames carry a fresh surface.
        if statusRaw != SCFrameStatus.complete.rawValue { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        onFrame?(pixelBuffer, pts)
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.error("capture stopped: \(error.localizedDescription)")
        self.stream = nil
        onStoppedWithError?()
    }
}
