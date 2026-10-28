import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox
import ObjCTry

enum MicError: LocalizedError {
    case permissionDenied
    case noInputDevice
    case formatUnavailable
    case engineFailed(String)
    case silentInput

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Microphone access denied — enable My Flow in System Settings → Privacy → Microphone"
        case .noInputDevice:
            return "No microphone available — check your input device"
        case .formatUnavailable:
            return "Microphone format unusable — try switching input device"
        case .engineFailed(let m):
            return "Microphone error: \(m)"
        case .silentInput:
            return "Microphone captured no audio — check input device / mute switch"
        }
    }
}

/// Records mic audio to 16 kHz mono Int16 and publishes RMS levels.
///
/// TWO INVARIANTS, both learned the hard way:
///
/// 1. A fresh AVAudioEngine is built for EVERY recording. A long-lived engine
///    goes stale whenever the default input device changes (AirPods, display
///    mic) — its input format degrades, the converter silently dies, and the
///    app "records" while capturing nothing.
///
/// 2. That fresh engine is built BEFORE the key is pressed, not after.
///    Measured on this Mac: building it costs ~110 ms (inputNode format query
///    73 ms, installTap 13 ms, prepare 25 ms) while engine.start() costs only
///    ~30 ms. Pre-building ("arming") moves 110 ms off the keypress. Crucially
///    the mic is NOT live while armed — kAudioDevicePropertyDeviceIsRunning-
///    Somewhere stays `idle` through prepare() and only flips at start(), so
///    the orange recording indicator behaves exactly as before.
final class AudioRecorder {

    /// A fully built, prepared, not-yet-started capture graph.
    private final class Armed {
        let engine: AVAudioEngine
        let converter: AVAudioConverter
        let inFormat: AVAudioFormat
        let deviceID: AudioDeviceID
        init(engine: AVAudioEngine, converter: AVAudioConverter,
             inFormat: AVAudioFormat, deviceID: AudioDeviceID) {
            self.engine = engine; self.converter = converter
            self.inFormat = inFormat; self.deviceID = deviceID
        }
        func dispose() {
            try? AudioRecorder.objc("dispose") {
                engine.inputNode.removeTap(onBus: 0)
                if engine.isRunning { engine.stop() }
                engine.reset()
            }
        }
    }

    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var pcm = Data()
    private let lock = NSLock()
    private(set) var isRecording = false
    private var startedAt = Date()

    private var armed: Armed?
    private let armLock = NSLock()
    private var healthTimer: Timer?
    private(set) var restarts = 0
    private var lastRestartAt = Date.distantPast
    private var lastRearmAt = Date.distantPast
    private var lastConfigChangeAt = Date.distantPast
    private var armRetries = 0
    private var deviceListenerInstalled = false
    private static let armQueue = DispatchQueue(label: "myflow.mic.arm", qos: .userInitiated)

    var onLevel: ((Float) -> Void)?

    static let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                            sampleRate: 16000, channels: 1,
                                            interleaved: true)!

    /// Bytes captured so far — the ground truth for "is the mic actually live".
    var capturedBytes: Int {
        lock.lock(); defer { lock.unlock() }
        return pcm.count
    }

    /// True only when the engine really is running. Used to detect a wedged
    /// recorder so a hotkey press can never be silently swallowed forever.
    var isHealthy: Bool { engine?.isRunning == true }

    static func permissionGranted() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static func requestPermissionIfNeeded() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        }
    }

    // MARK: - Arming (the latency fix)

    /// Build the next recording's engine now, off the main thread, so the next
    /// keypress only has to call start(). Safe to call as often as you like.
    func armAsync() {
        Self.armQueue.async { [weak self] in self?.arm() }
    }

    /// Throw away the armed graph and build a new one — used after system wake,
    /// when a graph built before sleep can be silently stale.
    func rearmAsync() {
        Self.armQueue.async { [weak self] in
            guard let self, !self.isRecording else { return }
            self.disarm()
            self.arm()
        }
    }

    private func arm() {
        armLock.lock()
        installDeviceListenerLocked()
        guard !isRecording, armed == nil,
              AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            armLock.unlock(); return
        }
        armLock.unlock()

        let t0 = DispatchTime.now().uptimeNanoseconds
        let built: Armed
        do {
            built = try buildGraph()
            // allocates buffers; does NOT open the mic
            try Self.objc("prepare") { built.engine.prepare() }
        } catch {
            // Usually a Bluetooth device mid-switch. Never crash; try again
            // once the route has settled so the next keypress is still fast.
            armRetries += 1
            mflog("mic arm failed (\(error.localizedDescription)) — retry #\(armRetries)")
            if armRetries <= 4 {
                Self.armQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.arm() }
            }
            return
        }
        armRetries = 0
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
        mflog(String(format: "mic armed in %.0f ms (device %u)", ms, built.deviceID))

        armLock.lock()
        if isRecording || armed != nil {
            armLock.unlock(); built.dispose(); return
        }
        armed = built
        armLock.unlock()
    }

    /// Hand over the armed graph if it still matches the current input device.
    private func takeArmed() -> Armed? {
        armLock.lock(); defer { armLock.unlock() }
        guard let a = armed else { return nil }
        armed = nil
        let current = AudioDevices.captureInputID()
        guard current != 0, current == a.deviceID else {
            mflog("armed mic was for device \(a.deviceID), now \(current) — discarding")
            a.dispose()
            return nil
        }
        return a
    }

    private func disarm() {
        armLock.lock()
        let a = armed
        armed = nil
        armLock.unlock()
        a?.dispose()
    }

    /// Re-arm whenever the default input device changes, so the armed graph is
    /// never the stale one that used to cause silent "recordings".
    private func installDeviceListenerLocked() {
        guard !deviceListenerInstalled else { return }
        deviceListenerInstalled = true
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, Self.armQueue
        ) { [weak self] _, _ in
            guard let self, !self.isRecording else { return }
            mflog("default input device changed — re-arming mic")
            self.disarm()
            self.arm()
        }
        // A Bluetooth headset switching into mic mode changes the input format
        // and STOPS the running engine (verified: AirPods Pro go 48 kHz A2DP ->
        // 24 kHz mic ~540 ms after start()). Delivered on main so it can never
        // race start()/teardown(), which are also main-thread.
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.lastConfigChangeAt = Date()
            if self.isRecording {
                // Let the route settle before rebuilding; rebuilding mid-switch
                // reads a stale format and the engine just stops again.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self.restartCapture(reason: "input configuration changed")
                }
            } else {
                guard Date().timeIntervalSince(self.lastRearmAt) > 0.4 else { return }
                self.lastRearmAt = Date()
                mflog("audio engine configuration changed — re-arming mic")
                Self.armQueue.async { self.disarm(); self.arm() }
            }
        }
    }

    /// The expensive part: query the input format, build the converter, install
    /// the tap. ~110 ms. Runs off the main thread when arming.
    private func buildGraph() throws -> Armed {
        guard AVCaptureDevice.default(for: .audio) != nil else { throw MicError.noInputDevice }
        let deviceID = AudioDevices.captureInputID()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if deviceID != 0, deviceID != AudioDevices.defaultInputID(), let unit = input.audioUnit {
            var dev = deviceID
            let st = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0, &dev,
                                          UInt32(MemoryLayout<AudioDeviceID>.size))
            if st != noErr { mflog("could not select input device \(deviceID): \(st)") }
        }
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            mflog("mic input format invalid (\(inFormat.sampleRate)Hz, \(inFormat.channelCount)ch)")
            throw MicError.noInputDevice
        }
        let firstConv = try installCaptureTap(on: input, format: inFormat)
        return Armed(engine: engine, converter: firstConv, inFormat: inFormat,
                     deviceID: deviceID)
    }

    /// Installs the capture tap and returns the converter for `inFormat`. The
    /// tap rebuilds its converter if the hardware format changes under it.
    private func installCaptureTap(on input: AVAudioInputNode,
                                   format inFormat: AVAudioFormat) throws -> AVAudioConverter {
        guard let firstConv = AVAudioConverter(from: inFormat, to: Self.targetFormat) else {
            mflog("AVAudioConverter nil for \(inFormat)")
            throw MicError.formatUnavailable
        }
        // The tap block runs serially on one audio thread, so this is safe.
        var conv = firstConv
        // format: nil = whatever the hardware delivers. Passing an explicit
        // format raises an NSException (uncatchable in Swift -> crash) when a
        // Bluetooth device switches rate between the query and this call.
        try Self.objc("installTap") {
            input.installTap(onBus: 0, bufferSize: 2048, format: nil) { [weak self] buffer, _ in
                guard let self, self.isRecording else { return }
                if buffer.format != conv.inputFormat {
                    guard let c = AVAudioConverter(from: buffer.format, to: Self.targetFormat) else { return }
                    conv = c
                }
                if let ch = buffer.floatChannelData?[0] {
                    let n = Int(buffer.frameLength)
                    var sum: Float = 0
                    for i in 0..<n { sum += ch[i] * ch[i] }
                    let rms = sqrt(sum / Float(max(n, 1)))
                    self.onLevel?(min(1.0, sqrt(rms) * 2.2))
                }
                let ratio = Self.targetFormat.sampleRate / buffer.format.sampleRate
                let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 16)
                guard let out = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: capacity) else { return }
                var fed = false
                conv.convert(to: out, error: nil) { _, status in
                    if fed { status.pointee = .noDataNow; return nil }
                    fed = true; status.pointee = .haveData; return buffer
                }
                if out.frameLength > 0, let ch = out.int16ChannelData?[0] {
                    let bytes = Data(bytes: ch, count: Int(out.frameLength) * 2)
                    self.lock.lock(); self.pcm.append(bytes); self.lock.unlock()
                }
            }
        }
        return firstConv
    }

    /// Runs AVAudioEngine calls that may raise Objective-C exceptions and turns
    /// those into Swift errors instead of an abort().
    static func objc(_ what: String, _ body: () throws -> Void) throws {
        var swiftError: Error?
        var nsError: NSError?
        let ok = MFTryObjC({
            do { try body() } catch { swiftError = error }
        }, &nsError)
        if let swiftError { throw swiftError }
        if !ok {
            let msg = nsError?.localizedDescription ?? "unknown exception"
            mflog("\(what) raised: \(msg)")
            throw MicError.engineFailed(msg)
        }
    }

    // MARK: - Mid-recording recovery

    /// The engine can die under a live recording — a Bluetooth headset entering
    /// mic mode stops it outright. Rebuild the graph in place at the NEW format
    /// and keep every byte captured so far. This is what turns the old
    /// "Microphone captured no audio" dead end into a ~200 ms hiccup.
    private func restartCapture(reason: String) {
        guard isRecording, restarts < 8,
              Date().timeIntervalSince(lastRestartAt) > 0.4 else { return }
        restarts += 1
        lastRestartAt = Date()
        mflog("mic restart #\(restarts) (\(reason)) — keeping \(capturedBytes) bytes")

        // NOTE: pcm is deliberately NOT cleared — audio already captured stays.
        // Restart IN PLACE on the same engine. Building a new engine and
        // releasing the old one makes a Bluetooth headset see the mic close,
        // and it flips back to music mode (48 kHz) — the old 24k/48k flapping
        // that captured nothing.
        if let e = engine {
            do {
                let input = e.inputNode
                let fmt = input.outputFormat(forBus: 0)
                guard fmt.sampleRate > 0, fmt.channelCount > 0 else { throw MicError.noInputDevice }
                try Self.objc("restart in place") {
                    input.removeTap(onBus: 0)
                    if e.isRunning { e.stop() }
                }
                converter = try installCaptureTap(on: input, format: fmt)
                try Self.objc("restart start") {
                    e.prepare()
                    try e.start()
                }
                mflog(String(format: "mic restarted in place at %.0f Hz", fmt.sampleRate))
                return
            } catch {
                mflog("in-place restart failed (\(error.localizedDescription)) — rebuilding engine")
                try? Self.objc("restart teardown") {
                    e.inputNode.removeTap(onBus: 0)
                    if e.isRunning { e.stop() }
                    e.reset()
                }
            }
        }
        engine = nil
        converter = nil
        do {
            let built = try buildGraph()
            try Self.objc("restart start") {
                built.engine.prepare()
                try built.engine.start()
            }
            engine = built.engine
            converter = built.converter
            mflog(String(format: "mic restarted at %.0f Hz", built.inFormat.sampleRate))
        } catch {
            mflog("mic restart failed: \(error.localizedDescription)")
        }
    }

    /// engine.start() returning true is not proof the mic is live — the engine
    /// can stop itself half a second later. Poll and repair.
    private func startHealthMonitor() {
        healthTimer?.invalidate()
        let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self, self.isRecording else { return }
            // A route change is still in flight — its own handler restarts.
            if self.engine?.isRunning != true,
               Date().timeIntervalSince(self.lastConfigChangeAt) > 0.35 {
                self.restartCapture(reason: "engine stopped itself")
            }
        }
        RunLoop.main.add(t, forMode: .common)
        healthTimer = t
    }

    /// Called by the Engine watchdog: audio should be flowing by now but is not.
    func forceRestartIfSilent() {
        guard isRecording, capturedBytes == 0 else { return }
        restartCapture(reason: "no audio yet")
    }

    // MARK: - Recording

    func start() throws {
        // Never trust stale state: if we think we're recording but the engine
        // isn't running, reset rather than refusing (this was a hard lockout).
        if isRecording && !isHealthy {
            mflog("recorder was wedged (isRecording but engine dead) — force reset")
            forceReset()
        }
        guard !isRecording else { throw MicError.engineFailed("already recording") }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            throw MicError.permissionDenied
        default:
            throw MicError.permissionDenied
        }

        lock.lock(); pcm.removeAll(); lock.unlock()
        restarts = 0

        let t0 = DispatchTime.now().uptimeNanoseconds
        func elapsedMS() -> Double { Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000 }

        // Fast path: the graph was built before the key was pressed.
        if let a = takeArmed() {
            do {
                try Self.objc("start") { try a.engine.start() }
                engine = a.engine
                converter = a.converter
                isRecording = true
                startedAt = Date()
                startHealthMonitor()
                mflog(String(format: "mic live in %.0f ms (armed)", elapsedMS()))
                return
            } catch {
                mflog("armed mic failed to start (\(error.localizedDescription)) — rebuilding")
                a.dispose()
            }
        }

        // Cold path: build and start in one go (~140 ms).
        let built = try buildGraph()
        do {
            try Self.objc("cold start") {
                built.engine.prepare()
                try built.engine.start()
            }
        } catch {
            built.dispose()
            throw MicError.engineFailed(error.localizedDescription)
        }
        engine = built.engine
        converter = built.converter
        isRecording = true
        startedAt = Date()
        startHealthMonitor()
        mflog(String(format: "mic live in %.0f ms (cold — not armed)", elapsedMS()))
    }

    /// Stops and returns (wavData, durationSeconds), or nil if nothing usable
    /// was captured. `capturedBytes` distinguishes "too short" from "dead mic".
    func stop() -> (Data, Double)? {
        guard isRecording else { return nil }
        let samples = teardown()
        let duration = Double(samples.count) / (16000.0 * 2.0)
        guard duration >= 0.4 else { return nil }
        return (Self.wav(from: samples), duration)
    }

    /// Cancels and RETURNS whatever was captured, so an accidental Esc can be
    /// undone. Returns nil only when nothing meaningful was recorded.
    @discardableResult
    func cancel() -> (Data, Double)? {
        guard isRecording else { return nil }
        let samples = teardown()
        let duration = Double(samples.count) / (16000.0 * 2.0)
        guard duration >= 1.0 else { return nil }
        return (Self.wav(from: samples), duration)
    }

    /// Unconditional teardown — safe to call in any state. Guarantees the
    /// recorder can never stay stuck "recording".
    func forceReset() {
        _ = teardown()
    }

    @discardableResult
    private func teardown() -> Data {
        isRecording = false
        healthTimer?.invalidate()
        healthTimer = nil
        if let engine {
            try? Self.objc("teardown") {
                engine.inputNode.removeTap(onBus: 0)
                if engine.isRunning { engine.stop() }
                engine.reset()
            }
        }
        engine = nil
        converter = nil
        lock.lock(); let samples = pcm; pcm.removeAll(); lock.unlock()
        armAsync()          // get the next recording's graph ready immediately
        return samples
    }

    var elapsed: TimeInterval { isRecording ? Date().timeIntervalSince(startedAt) : 0 }

    static func wav(from samples: Data) -> Data {
        var d = Data()
        func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append("RIFF".data(using: .ascii)!); le32(UInt32(36 + samples.count))
        d.append("WAVE".data(using: .ascii)!); d.append("fmt ".data(using: .ascii)!)
        le32(16); le16(1); le16(1); le32(16000); le32(32000); le16(2); le16(16)
        d.append("data".data(using: .ascii)!); le32(UInt32(samples.count))
        d.append(samples)
        return d
    }
}
