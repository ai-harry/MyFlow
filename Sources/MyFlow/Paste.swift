import AppKit
import CoreGraphics

/// Clipboard + synthetic keystrokes. Needs Accessibility permission.
enum Paste {

    private static func postKey(_ key: CGKeyCode, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false)
        down?.flags = flags; up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    /// Insert text at the cursor by pasting. The result is LEFT on the
    /// clipboard so the user can paste it again anywhere.
    static func insert(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        postKey(9, flags: .maskCommand)   // Cmd+V (kVK_ANSI_V = 9)
    }

    /// Grab the current selection by simulating Cmd+C. Returns nil if nothing
    /// was selected. Restores the previous clipboard.
    static func captureSelection() async -> String? {
        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)
        let before = pb.changeCount
        postKey(8, flags: .maskCommand)   // Cmd+C (kVK_ANSI_C = 8)
        try? await Task.sleep(nanoseconds: 250_000_000)
        var result: String?
        if pb.changeCount != before {
            result = pb.string(forType: .string)
        }
        if let saved {
            pb.clearContents()
            pb.setString(saved, forType: .string)
        }
        if let r = result, !r.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return r
        }
        return nil
    }

    static func frontmostAppName() -> String {
        NSWorkspace.shared.frontmostApplication?.localizedName ?? "Unknown"
    }
}

enum Sounds {
    private static var cache: [String: NSSound] = [:]
    private static let names = ["Tink", "Morse", "Submarine", "Basso", "Pop", "Glass"]

    /// Decoding an NSSound on the first press costs milliseconds we do not
    /// have; load them all at launch instead.
    static func preload() {
        for n in names where cache[n] == nil {
            cache[n] = NSSound(contentsOfFile: "/System/Library/Sounds/\(n).aiff", byReference: true)
        }
    }

    static func play(_ name: String) {
        guard AppSettings.shared.soundsEnabled else { return }
        if cache[name] == nil {
            cache[name] = NSSound(contentsOfFile: "/System/Library/Sounds/\(name).aiff", byReference: true)
        }
        guard let s = cache[name] else { return }
        if s.isPlaying { s.stop() }
        s.play()
    }
}
