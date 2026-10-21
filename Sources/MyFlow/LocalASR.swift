import Foundation
import FluidAudio

/// On-device speech recognition: NVIDIA Parakeet TDT via FluidAudio (CoreML / ANE).
/// Models download once from HuggingFace to FluidAudio's default cache, then stay resident.
enum LocalASR {
    /// v3 (multilingual, library default) matched Cohere best in benchmarks; .v2 is English-only.
    private static let modelVersion: AsrModelVersion = .v3

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _ready = false
    nonisolated(unsafe) private static var _loading = false

    /// true once the model is loaded and ready.
    static var isReady: Bool {
        lock.lock(); defer { lock.unlock() }
        return _ready
    }

    /// Starts downloading/loading the model in the background. Safe to call repeatedly.
    static func warmUp() {
        lock.lock()
        if _ready || _loading { lock.unlock(); return }
        _loading = true
        lock.unlock()
        Task.detached(priority: .utility) {
            let t0 = Date()
            do {
                try await Engine.shared.load()
                finish(ok: true)
                mflog(String(format: "local ASR ready in %.1fs", Date().timeIntervalSince(t0)))
            } catch {
                finish(ok: false)
                mflog("local ASR load failed: \(error)")
            }
        }
    }

    /// nil when the local model isn't loaded yet. wav = 16 kHz mono Int16 PCM WAV, 44-byte header.
    static func transcribe(wav: Data) async throws -> String? {
        guard isReady else { return nil }
        let samples = floats(fromWAV: wav)
        guard !samples.isEmpty else { return "" }
        let t0 = Date()
        let text = try await Engine.shared.run(samples)
        mflog(String(format: "local ASR: %.1fs audio in %.2fs", Double(samples.count) / 16000.0,
                     Date().timeIntervalSince(t0)))
        return text
    }

    private static func finish(ok: Bool) {
        lock.lock(); defer { lock.unlock() }
        if ok { _ready = true }
        _loading = false
    }

    private static func floats(fromWAV wav: Data) -> [Float] {
        guard wav.count > 44 else { return [] }
        let n = (wav.count - 44) / 2
        return wav.withUnsafeBytes { raw -> [Float] in
            let p = raw.baseAddress!.advanced(by: 44).assumingMemoryBound(to: Int16.self)
            return (0..<n).map { Float(Int16(littleEndian: p[$0])) / 32768.0 }
        }
    }

    private actor Engine {
        static let shared = Engine()
        private var manager: AsrManager?

        func load() async throws {
            let models = try await AsrModels.downloadAndLoad(version: LocalASR.modelVersion)
            let m = AsrManager(config: .default)
            try await m.loadModels(models)
            // Warm-up pass so the first real call doesn't pay CoreML specialization cost.
            var st = try TdtDecoderState(decoderLayers: await m.decoderLayerCount)
            _ = try? await m.transcribe([Float](repeating: 0, count: 16000), decoderState: &st)
            manager = m
        }

        func run(_ samples: [Float]) async throws -> String {
            guard let m = manager else { return "" }
            var st = try TdtDecoderState(decoderLayers: await m.decoderLayerCount)
            let r = try await m.transcribe(samples, decoderState: &st)
            return r.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
