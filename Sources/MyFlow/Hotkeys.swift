import Foundation
import CoreGraphics
import AppKit
import ApplicationServices

/// Appends a line to ~/Library/Application Support/MyFlow/debug.log
func mflog(_ s: String) {
    let url = AppSettings.supportDir.appendingPathComponent("debug.log")
    let line = "\(Date()) \(s)\n"
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
    } else {
        try? line.data(using: .utf8)?.write(to: url)
    }
}

/// Fn-key state machine via CGEventTap (Accessibility required).
///
///   hold Fn            -> push-to-talk, release Fn = stop+transcribe
///   Fn+Cmd             -> latch hands-free, fresh Fn press = stop
///   Fn+Space           -> AI mode (latched), fresh Fn press = stop+execute
///   quick Fn tap idle  -> nothing
///   Esc while active   -> cancel
///   Opt+1..9           -> transforms on current selection (if enabled)
final class HotkeyManager {
    static let shared = HotkeyManager()

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var watchdog: Timer?
    private var lastEventAt = Date()
    private var fnIsDown = false
    private var fnDownAt = Date.distantPast
    private var ignoreNextFnUp = false

    private let kSpace: Int64 = 49
    private let kEsc: Int64 = 53
    private let kFn: Int64 = 63
    private let digitKeys: [Int64: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]

    func install() -> Bool {
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let mgr = Unmanaged<HotkeyManager>.fromOpaque(refcon!).takeUnretainedValue()
            return mgr.handle(type: type, event: event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            mflog("tapCreate FAILED (trusted=\(AXIsProcessTrusted()))")
            return false
        }
        mflog("tap installed OK (trusted=\(AXIsProcessTrusted()))")
        self.tap = tap
        let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
        self.runLoopSource = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        startWatchdog()
        return true
    }

    /// macOS silently disables event taps it deems slow (App Nap makes this
    /// common after long idle). A disabled tap gets NO callbacks, so it can't
    /// heal from inside the callback — this timer revives it from outside.
    private func startWatchdog() {
        watchdog?.invalidate()
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            guard let self, let tap = self.tap else { return }
            if !CGEvent.tapIsEnabled(tap: tap) {
                mflog("watchdog: tap was disabled — re-enabling")
                CGEvent.tapEnable(tap: tap, enable: true)
                if !CGEvent.tapIsEnabled(tap: tap) {
                    mflog("watchdog: re-enable failed — reinstalling tap")
                    self.reinstall()
                }
                return
            }
            // A tap can also go stale while still reporting "enabled" — it
            // simply stops delivering events. Detect by silence and rebuild;
            // a reinstall costs milliseconds and is harmless.
            if Date().timeIntervalSince(self.lastEventAt) > 240,
               !Engine.shared.isActive {
                mflog("watchdog: no key events for 4 min — rebuilding tap as a precaution")
                self.lastEventAt = Date()
                self.reinstall()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        watchdog = t
    }

    /// Tear down and rebuild the tap from scratch (used after system wake,
    /// when a stale tap can report enabled yet deliver nothing).
    func reinstall() {
        teardown()
        let ok = install()
        mflog("tap reinstall after wake/failure: \(ok ? "OK" : "FAILED (permission?)")")
    }

    private func teardown() {
        watchdog?.invalidate(); watchdog = nil
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
            runLoopSource = nil
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            self.tap = nil
        }
        fnIsDown = false
        ignoreNextFnUp = false
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        lastEventAt = Date()
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        let engine = Engine.shared

        if type == .flagsChanged {
            mflog("flagsChanged keycode=\(keycode) fn=\(flags.contains(.maskSecondaryFn)) shift=\(flags.contains(.maskShift)) cmd=\(flags.contains(.maskCommand))")
            if keycode == kFn {
                let nowDown = flags.contains(.maskSecondaryFn)
                if nowDown != fnIsDown {
                    fnIsDown = nowDown
                    if nowDown {
                        fnDown(engine, shiftHeld: flags.contains(.maskShift),
                               cmdHeld: flags.contains(.maskCommand))
                    } else { fnUp(engine) }
                }
            } else if keycode == 55 || keycode == 54 {  // left/right Cmd
                // Synchronous: the tap runs on the main run loop, so acting
                // inline removes the fn+cmd race (async hop made latch miss).
                if flags.contains(.maskCommand), fnIsDown, engine.phaseIsPTT {
                    MainActor.assumeIsolated { engine.latch() }
                }
            }
            return Unmanaged.passUnretained(event)
        }

        // keyDown
        if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
            return Unmanaged.passUnretained(event)
        }
        if keycode == kSpace, fnIsDown || flags.contains(.maskSecondaryFn) {
            if engine.phaseIsPTT || engine.phaseIsIdle {
                ignoreNextFnUp = true
                MainActor.assumeIsolated { engine.enterAIMode() }
                return nil  // consume the space
            }
        }
        if keycode == kEsc, engine.isActive {
            MainActor.assumeIsolated { engine.cancel() }
            return nil
        }
        // ⌥Z — recover the recording that was just cancelled with Esc
        if keycode == 6, flags.contains(.maskAlternate), !flags.contains(.maskCommand),
           engine.hasRecoverableCancel {
            MainActor.assumeIsolated { engine.recoverLastCancelled() }
            return nil
        }
        // ⌥Y / ⌥N — only while a dictionary suggestion is showing
        if engine.suggestionActive, flags.contains(.maskAlternate) {
            if keycode == 16 {   // Y
                MainActor.assumeIsolated { engine.acceptSuggestion() }
                return nil
            }
            if keycode == 45 {   // N
                MainActor.assumeIsolated { engine.dismissSuggestion() }
                return nil
            }
        }
        if let slot = digitKeys[keycode],
           flags.contains(.maskAlternate), !flags.contains(.maskCommand),
           AppSettings.shared.transformHotkeysEnabled,
           Store.shared.transforms().contains(where: { $0.slot == slot }) {
            DispatchQueue.main.async { engine.runTransform(slot: slot) }
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    private func fnDown(_ engine: Engine, shiftHeld: Bool, cmdHeld: Bool) {
        if engine.phaseIsIdle {
            fnDownAt = Date()
            if shiftHeld {
                // Shift+Fn: hands-free loud mode, latched immediately.
                ignoreNextFnUp = true
                MainActor.assumeIsolated { engine.startLoud() }
            } else if cmdHeld {
                // Cmd was already down when Fn landed: hands-free latch now.
                ignoreNextFnUp = true
                MainActor.assumeIsolated { engine.startLatched() }
            } else {
                ignoreNextFnUp = false
                MainActor.assumeIsolated { engine.startPTT() }
            }
        } else if engine.phaseIsLatchedOrAI {
            // fresh Fn press stops a latched/loud/ai session
            ignoreNextFnUp = true
            MainActor.assumeIsolated { engine.stopAndProcess() }
        }
    }

    private func fnUp(_ engine: Engine) {
        if ignoreNextFnUp { ignoreNextFnUp = false; return }
        if engine.phaseIsPTT {
            let held = Date().timeIntervalSince(fnDownAt)
            MainActor.assumeIsolated {
                if held < 0.3 { engine.cancel(silent: true) }  // stray tap
                else { engine.stopAndProcess() }
            }
        }
    }
}
