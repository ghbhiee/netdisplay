import Foundation
import CoreImage
import CoreVideo
import CoreGraphics
import ImageIO
import Metal

/// Converts decoded CVPixelBuffers (NV12 from VideoToolbox) into displayable
/// CGImages via a GPU-backed CIContext (handles YUV→RGB using the buffer's
/// attached color attachments). Shared by the live NSWindow and PNG snapshots.
final class FrameRenderer {
    private let ciContext: CIContext

    init() {
        // Prefer GPU; fall back to default if no Metal device.
        if let dev = MTLCreateSystemDefaultDevice() {
            ciContext = CIContext(mtlDevice: dev)
        } else {
            ciContext = CIContext(options: [.useSoftwareRenderer: false])
        }
    }

    func cgImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        return ciContext.createCGImage(ci, from: ci.extent)
    }

    /// Save one decoded frame to PNG — used for headless verification of the
    /// decode → convert path.
    @discardableResult
    func savePNG(_ pixelBuffer: CVPixelBuffer, to url: URL) -> Bool {
        guard let img = cgImage(from: pixelBuffer),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(dest, img, nil)
        return CGImageDestinationFinalize(dest)
    }
}
