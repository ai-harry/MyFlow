import Foundation
import AppKit
import SwiftUI

/// Central state machine + pipeline orchestration. UI observes this.
@MainActor
final class Engine: ObservableObject {
    static let shared = Engine()

    enum Phase: Equatable {
        case idle
        case ptt          // hold-Fn dictation (LLM cleanup)
        case latched      // Fn+Cmd hands-free dictation (LLM cleanup)
        case loud         // Shift+Fn hands-free, noise-aware cleanup
        case ai           // Fn+Space AI command
        case processing(String)
        case flash(String)   // brief result display
        case error(String)
        case suggestion(String)   // "add word to dictionary?" capsule
    }

    @Published var phase: Phase = .idle
    @Published var levels: [Float] = Array(repeating: 0.02, count: 24)
    @Published var historyVersion = 0   // bump to refresh UI lists
    /// True between "recording started" and "first audio actually arrived".
    /// Bluetooth headsets need ~1 s to switch into mic mode; the bar says so
    /// rather than pretending to listen while the hardware is still switching.
    @Published var micWarming = false

    private let recorder = AudioRecorder()
    private var aiSelection: String?
    private var aiScreenshot: String?
    private var flashTask: Task<Void, Never>?
    private var lastPasted = ""
    private var fieldReadTask: Task<Void, Never>?
    private var audioWatchdog: Task<Void, Never>?
    private var pendingDuck: Task<Void, Never>?
    private var lastCancelledAudio: String?

    nonisolated init() {}

    // Phase queries — the event tap runs on the main run loop, so these are
    // main-thread calls despite the nonisolated context of the C callback.
    /// True when a NEW recording may begin. Deliberately includes
    /// .processing and .suggestion: transcription of an earlier clip runs in
    /// the background and must never swallow a hotkey press.
    nonisolated var phaseIsIdle: Bool {
        MainActor.assumeIsolated {
            switch self.phase {
            case .idle, .flash, .error, .processing, .suggestion: return true
            case .ptt, .latched, .loud, .ai: return false
            }
        }
    }
    nonisolated var phaseIsPTT: Bool { MainActor.assumeIsolated { self.phase == .ptt } }
    nonisolated var phaseIsLatchedOrAI: Bool {
        MainActor.assumeIsolated { self.phase == .latched || self.phase == .loud || self.phase == .ai }
    }
    nonisolated var isActive: Bool {
        MainActor.assumeIsolated {
            switch self.phase { case .ptt, .latched, .loud, .ai: return true; default: return false }
        }
    }

    // MARK: - Recording control

    func startPTT() {
        guard canBeginRecording else { return }
        beginRecording(phase: .ptt)
    }

    /// Shift+Fn: start hands-free immediately in noise-aware "loud" mode.
    func startLoud() {
        guard canBeginRecording else { return }
        beginRecording(phase: .loud)
        Sounds.play("Morse")
    }

    func latch() {
        if phase == .ptt { phase = .latched; Sounds.play("Morse") }
    }

    /// Fn pressed while Cmd already held: hands-free from the first moment.
    func startLatched() {
        guard canBeginRecording else { return }
        beginRecording(phase: .latched)
        Sounds.play("Morse")
    }

    func enterAIMode() {
        if !recorder.isRecording || phase == .ptt {
            if !recorder.isRecording { beginRecording(phase: .ai) } else { phase = .ai }
            Sounds.play("Submarine")
            aiSelection = nil; aiScreenshot = nil
            Task {
                self.aiSelection = await Paste.captureSelection()
                self.aiScreenshot = await Screenshot.captureMainDisplayJPEG()
            }
        }
    }

    /// Build the capture graph ahead of the first keypress (see AudioRecorder).
    func prearmMic() { recorder.armAsync() }

    /// Rebuild it from scratch (after sleep/wake the old one can be stale).
    func rearmMic() { recorder.rearmAsync() }

    /// A recorder that claims to be recording but whose engine is dead must
    /// never block new recordings — that was a force-quit-only lockout.
    private var canBeginRecording: Bool {
        if recorder.isRecording && !recorder.isHealthy {
            mflog("engine: recorder wedged — resetting before new recording")
            recorder.forceReset()
            unduck()
        }
        return !recorder.isRecording
    }

    private func beginRecording(phase newPhase: Phase) {
        // ORDER MATTERS. The capsule is painted FIRST, in the same run-loop
        // turn as the keypress, so the bar reacts the instant you press Fn.
        // Audio setup follows (~30 ms with a pre-armed engine). If start()
        // throws, phase is overwritten with .error before SwiftUI ever draws,
        // so there is no flicker.
        resetLevels()
        micWarming = true
        phase = newPhase
        do {
            recorder.onLevel = { [weak self] lvl in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if self.micWarming { self.micWarming = false }   // mic is live
                    self.levels.removeFirst()
                    self.levels.append(lvl)
                }
            }
            try recorder.start()
            duckWhenMicSettles()  // silence background media while the mic is live
            if newPhase == .ptt { Sounds.play("Tink") }
            startAudioWatchdog()
        } catch {
            Sounds.play("Basso")
            mflog("beginRecording failed: \(error.localizedDescription)")
            phase = .error(error.localizedDescription)
            scheduleIdle(after: 5)
        }
    }

    /// Muting the output of a Bluetooth headset while it is still switching
    /// from music to mic mode can bounce it back to music mode, killing the
    /// recording. So for Bluetooth, wait out the ~1 s switch before ducking.
    private func duckWhenMicSettles() {
        pendingDuck?.cancel()
        guard AudioDevices.isBluetooth(AudioDevices.captureInputID()) else {
            AudioDucking.duck(); return
        }
        pendingDuck = Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled, self.recorder.isRecording else { return }
            AudioDucking.duck()
        }
    }

    private func unduck() {
        pendingDuck?.cancel()
        pendingDuck = nil
        AudioDucking.unduck()
    }

    /// If no audio arrives, the mic is dead — say so loudly instead of letting
    /// the user talk into the void. But do NOT jump to that conclusion early:
    /// a Bluetooth headset (AirPods) takes ~0.5-0.9 s to switch into mic mode,
    /// and the engine stops itself while it does. Poll, nudge the recorder into
    /// rebuilding, and only give up after 4 s of genuine silence.
    private func startAudioWatchdog() {
        audioWatchdog?.cancel()
        audioWatchdog = Task {
            var elapsed = 0.0
            var nudged = false
            while elapsed < 4.0 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                elapsed += 0.25
                if Task.isCancelled || !self.recorder.isRecording { return }
                if self.recorder.capturedBytes > 0 { return }    // mic is live
                if elapsed >= 1.2, !nudged {
                    nudged = true
                    self.recorder.forceRestartIfSilent()
                }
            }
            guard !Task.isCancelled, self.recorder.isRecording,
                  self.recorder.capturedBytes == 0 else { return }
            mflog("MIC DEAD: no audio 4s after start (restarts=\(self.recorder.restarts)) — aborting")
            self.micWarming = false
            self.recorder.forceReset()
            unduck()
            Sounds.play("Basso")
            self.resetLevels()
            self.phase = .error(MicError.silentInput.localizedDescription)
            self.scheduleIdle(after: 5)
        }
    }

    /// Esc during a recording. Anything longer than a second is SAVED, not
    /// thrown away — an accidental cancel is recoverable with ⌥Z or from
    /// History.
    func cancel(silent: Bool = false) {
        micWarming = false
        audioWatchdog?.cancel()
        let mode = phase
        let salvaged = recorder.cancel()
        unduck()
        resetLevels()

        guard let (wav, duration) = salvaged else {
            if !silent { Sounds.play("Basso") }
            phase = .idle
            return
        }
        let path = Self.savePendingAudio(wav)
        Self.pruneAudio(keepNewest: 100)
        Store.shared.logDictation(raw: "", clean: "", app: Paste.frontmostAppName(),
                                  duration: duration,
                                  mode: mode == .loud ? "loud" : (mode == .ai ? "ai" : "dictation"),
                                  status: "cancelled", audio: path)
        historyVersion += 1
        lastCancelledAudio = path
        Sounds.play("Basso")
        mflog("cancelled recording SALVAGED (\(Int(duration))s) → \(path)")
        phase = .flash("Cancelled \(Int(duration))s — ⌥Z to recover")
        scheduleIdle(after: 8)
    }

    nonisolated var hasRecoverableCancel: Bool {
        MainActor.assumeIsolated {
            guard let p = self.lastCancelledAudio else { return false }
            return FileManager.default.fileExists(atPath: p)
        }
    }

    /// ⌥Z — transcribe the recording that was just cancelled.
    func recoverLastCancelled() {
        guard let path = lastCancelledAudio,
              FileManager.default.fileExists(atPath: path),
              let row = Store.shared.recentDictations(limit: 60)
                  .first(where: { $0.audioPath == path }) else {
            phase = .error("Nothing to recover"); scheduleIdle(after: 2); return
        }
        lastCancelledAudio = nil
        mflog("recovering cancelled recording \(path)")
        retryDictation(row)
    }

    func stopAndProcess() {
        let mode = phase
        micWarming = false
        audioWatchdog?.cancel()
        let bytesCaptured = recorder.capturedBytes
        guard let (wav, duration) = recorder.stop() else {
            unduck(); resetLevels()
            if bytesCaptured == 0 {
                Sounds.play("Basso")
                mflog("stop: zero bytes captured — reporting dead mic")
                phase = .error(MicError.silentInput.localizedDescription)
                scheduleIdle(after: 5)
            } else {
                phase = .idle   // genuinely just a very short tap
            }
            return
        }
        unduck()   // restore audio the moment the mic closes
        Sounds.play("Pop")
        resetLevels()
        let isAI = (mode == .ai)
        let isLoud = (mode == .loud)
        // Keep the audio for EVERY dictation (pruned to the last 100), so even
        // "successful" garbage output can be re-transcribed. Lesson of #673.
        let audioPath = Self.savePendingAudio(wav)
        Self.pruneAudio(keepNewest: 100)
        phase = .processing(isAI ? "Thinking…" : "Transcribing…")
        let selection = aiSelection
        let screenshot = aiScreenshot
        let app = Paste.frontmostAppName()
        let tStop = Date()

        Task {
            do {
                let raw = try await Services.transcribe(wav: wav, allowLocal: !isLoud)
                let tAsr = Date()
                var cleanupSecs = 0.0
                var cleanupKind = "none"
                guard !raw.isEmpty, !Self.isLikelyHallucination(raw, duration: duration) else {
                    self.reportResult(.error("Heard nothing"), idleAfter: 2); return
                }
                let output: String
                if isAI {
                    self.setProgress("Thinking…")
                    output = try await Services.aiCommand(
                        instruction: raw, selection: selection, screenshotB64: screenshot)
                } else {
                    // Short, simple transcripts are cleaned locally (no LLM round trip);
                    // everything else gets the LLM cleanup pass.
                    let tClean = Date()
                    if !isLoud, !Self.mayNeedVocabFix(raw), let fast = LocalCleanup.fastPath(raw) {
                        mflog("cleanup: local fast path")
                        cleanupKind = "local"
                        output = Services.applySnippets(fast)
                    } else {
                        self.setProgress("Cleaning up…")
                        cleanupKind = "llm"
                        output = Services.applySnippets(try await Services.cleanup(raw, loud: isLoud))
                    }
                    cleanupSecs = Date().timeIntervalSince(tClean)
                }
                Paste.insert(output)   // pastes AND leaves the result on the clipboard
                mflog(String(format: "pipeline: audio %.1fs | asr %.1fs | cleanup %.1fs (%@) | total %.1fs",
                             duration, tAsr.timeIntervalSince(tStop), cleanupSecs, cleanupKind,
                             Date().timeIntervalSince(tStop)))
                self.lastPasted = output
                self.scheduleFieldRead()
                Sounds.play("Glass")
                Store.shared.logDictation(raw: raw, clean: output, app: app,
                                          duration: duration,
                                          mode: isAI ? "ai" : (isLoud ? "loud" : "dictation"),
                                          status: "ok", audio: audioPath)
                self.historyVersion += 1
                self.reportResult(.flash(output), idleAfter: 3)
            } catch {
                // Audio already saved above — log a retryable failed entry.
                Sounds.play("Basso")
                Store.shared.logDictation(raw: "", clean: "", app: app,
                                          duration: duration,
                                          mode: isAI ? "ai" : (isLoud ? "loud" : "dictation"),
                                          status: "failed", audio: audioPath)
                self.historyVersion += 1
                self.reportResult(.error("Transcription failed — audio saved. Retry from the My Flow app."), idleAfter: 4)
            }
        }
    }

    /// Re-run a failed dictation from its saved audio. On success the result
    /// is copied to the clipboard (not pasted — focus has long moved on) and
    /// the history row updates in place.
    func retryDictation(_ d: Dictation) {
        guard !d.audioPath.isEmpty,
              let wav = try? Data(contentsOf: URL(fileURLWithPath: d.audioPath)) else {
            phase = .error("Saved audio is no longer available"); scheduleIdle(after: 3); return
        }
        phase = .processing("Retrying…")
        Task {
            do {
                // Retry always goes to the cloud: Parakeet is deterministic, so it
                // would just reproduce the output the user is retrying.
                let raw = try await Services.transcribe(wav: wav, allowLocal: false)
                let cleaned: String
                if d.mode != "loud", !Self.mayNeedVocabFix(raw), let fast = LocalCleanup.fastPath(raw) {
                    mflog("cleanup: local fast path")
                    cleaned = fast
                } else {
                    cleaned = try await Services.cleanup(raw, loud: d.mode == "loud")
                }
                let clean = Services.applySnippets(cleaned)
                Store.shared.resolveDictation(id: d.id, raw: raw, clean: clean)
                let pb = NSPasteboard.general
                pb.clearContents(); pb.setString(clean, forType: .string)
                Sounds.play("Glass")
                self.historyVersion += 1
                self.reportResult(.flash("Recovered & copied to clipboard"), idleAfter: 3)
            } catch {
                Sounds.play("Basso")
                self.reportResult(.error("Retry failed: \(error.localizedDescription)"), idleAfter: 4)
            }
        }
    }

    /// Keep only the newest N saved recordings; delete the rest.
    private static func pruneAudio(keepNewest: Int) {
        let dir = AppSettings.supportDir.appendingPathComponent("pending", isDirectory: true)
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let sorted = files.filter { $0.pathExtension == "wav" }.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da > db
        }
        for old in sorted.dropFirst(keepNewest) {
            try? fm.removeItem(at: old)
        }
    }

    private static func savePendingAudio(_ wav: Data) -> String {
        let dir = AppSettings.supportDir.appendingPathComponent("pending", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(Int(Date().timeIntervalSince1970))-\(Int.random(in: 1000...9999)).wav")
        try? wav.write(to: url)
        mflog("saved pending audio: \(url.lastPathComponent)")
        return url.path
    }

    /// Speech models hallucinate pleasantries on near-silent clips.
    private static func isLikelyHallucination(_ text: String, duration: Double) -> Bool {
        guard duration < 1.5 else { return false }
        let t = text.lowercased().trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))
        return ["thank you", "thanks", "you", "thank you for watching", "bye",
                "okay", "ok", "mm-hmm", "uh-huh", "so", "oh"].contains(t)
    }

    /// The local fast path skips the LLM, so it can't apply Dictionary
    /// spellings ("cloud code" -> "claude code"). Send anything that looks
    /// close to a dictionary word to the LLM instead.
    private static func mayNeedVocabFix(_ text: String) -> Bool {
        let vocabWords = Store.shared.vocab()
            .flatMap { $0.word.lowercased().split(separator: " ").map(String.init) }
            .filter { $0.count >= 4 }
        guard !vocabWords.isEmpty else { return false }
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { $0.count >= 4 }
        return words.contains { w in vocabWords.contains { FieldReader.levenshtein(w, $0) <= 2 } }
    }

    func runTransform(slot: Int) {
        guard let t = Store.shared.transforms().first(where: { $0.slot == slot }) else { return }
        phase = .processing(t.name + "…")
        Task {
            guard let selection = await Paste.captureSelection() else {
                self.phase = .error("No text selected"); self.scheduleIdle(after: 2); return
            }
            do {
                let out = try await Services.transform(t.prompt, selection: selection)
                Paste.insert(out)
                Sounds.play("Glass")
                Store.shared.logDictation(raw: selection, clean: out,
                                          app: Paste.frontmostAppName(), duration: 0, mode: "ai")
                self.historyVersion += 1
                self.reportResult(.flash(out), idleAfter: 3)
            } catch {
                self.reportResult(.error(error.localizedDescription), idleAfter: 4)
            }
        }
    }

    /// Update the progress label only when no new recording has begun.
    private func setProgress(_ label: String) {
        guard !recorder.isRecording else { return }
        phase = .processing(label)
    }

    /// Publish a result phase only if the user isn't mid-recording; a late
    /// arrival must never overwrite the live waveform.
    private func reportResult(_ p: Phase, idleAfter: Double) {
        guard !recorder.isRecording else {
            mflog("background job finished during a new recording — bar left alone")
            return
        }
        phase = p
        scheduleIdle(after: idleAfter)
    }

    // MARK: - spelling suggestion loop (R4)

    /// ~10s after a paste, quietly re-read the focused field via AX and look
    /// for a single-word spelling correction the user made.
    func scheduleFieldRead() {
        fieldReadTask?.cancel()
        let pasted = lastPasted
        fieldReadTask = Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled, case .idle = self.phase else { return }
            guard let current = FieldReader.readFocusedFieldText() else { return }
            let vocab = Store.shared.vocab().map(\.word)
            if let word = FieldReader.spellingFix(before: pasted, after: current, vocab: vocab) {
                self.phase = .suggestion(word)
                Sounds.play("Tink")
                self.scheduleIdle(after: 8)   // timeout: fade without adding
            }
        }
    }

    func acceptSuggestion() {
        guard case .suggestion(let word) = phase else { return }
        Store.shared.addVocab(word)
        historyVersion += 1
        Sounds.play("Glass")
        phase = .flash("Added “\(word)” to dictionary")
        scheduleIdle(after: 2.5)
        mflog("dictionary: added '\(word)' via ⌥Y")
    }

    func dismissSuggestion() {
        guard case .suggestion = phase else { return }
        phase = .idle
    }

    nonisolated var suggestionActive: Bool {
        MainActor.assumeIsolated {
            if case .suggestion = self.phase { return true }
            return false
        }
    }

    // MARK: - helpers

    private var isFlashOrError: Bool {
        if case .flash = phase { return true }
        if case .error = phase { return true }
        return false
    }

    private func normalizedPhase() -> Phase { isFlashOrError ? .idle : phase }

    private func scheduleIdle(after seconds: Double) {
        flashTask?.cancel()
        flashTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if !Task.isCancelled, !self.recorder.isRecording {
                if case .processing = self.phase {} else { self.phase = .idle }
            }
        }
    }

    private func resetLevels() {
        levels = Array(repeating: 0.02, count: levels.count)
    }
}
