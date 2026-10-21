import Foundation
import ScreenCaptureKit
import CoreGraphics
import AppKit

/// One-shot screen capture for AI context. Needs Screen Recording permission.
enum Screenshot {

    static func ensurePermission() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        CGRequestScreenCaptureAccess()
        return false
    }

    /// Captures the main display, downscaled, as base64 JPEG. Returns nil if
    /// permission is missing or capture fails.
    static func captureMainDisplayJPEG() async -> String? {
        guard CGPreflightScreenCaptureAccess() else { return nil }
        do {
            let content = try await SCShareableContent.current
            guard let display = content.displays.first else { return nil }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            // Downscale to ~1440px wide: plenty for reading text, cheap on tokens.
            let scale = min(1.0, 1440.0 / Double(display.width))
            config.width = Int(Double(display.width) * scale)
            config.height = Int(Double(display.height) * scale)
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config)
            let rep = NSBitmapImageRep(cgImage: image)
            guard let jpeg = rep.representation(using: .jpeg,
                                                properties: [.compressionFactor: 0.6]) else { return nil }
            return jpeg.base64EncodedString()
        } catch {
            NSLog("screenshot failed: \(error)")
            return nil
        }
    }
}
