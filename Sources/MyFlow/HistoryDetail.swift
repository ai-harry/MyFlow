import SwiftUI
import AVFoundation

struct HistoryDetailView: View {
    var d: Dictation
    var isProcessing: Bool
    var onRetry: () -> Void
    @State private var showOriginal = false

    private var failed: Bool { d.status == "failed" || d.status == "cancelled" }
    private var audioURL: URL? {
        guard !d.audioPath.isEmpty, FileManager.default.fileExists(atPath: d.audioPath) else { return nil }
        return URL(fileURLWithPath: d.audioPath)
    }
    private var text: String { showOriginal ? d.raw : d.clean }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.spacingL) {
                if failed {
                    ContentUnavailableView {
                        Label(d.status == "cancelled" ? "Recording Cancelled" : "Couldn't Transcribe",
                              systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(audioURL != nil ? "The audio was saved. You can try again."
                                             : "The saved audio is no longer available.")
                    } actions: {
                        if audioURL != nil {
                            Button("Retry", action: onRetry).disabled(isProcessing)
                        }
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    if !d.raw.isEmpty && d.raw != d.clean {
                        Picker("Version", selection: $showOriginal) {
                            Text("Cleaned").tag(false)
                            Text("Show Original").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: 260)
                    }
                    Text(text.isEmpty ? " " : text)
                        .font(.title3)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let url = audioURL {
                    AudioPlayerView(url: url, fallbackDuration: d.durationSec)
                }

                metadata
            }
            .padding(DS.spacingXL)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var metadata: some View {
        GroupBox {
            Grid(alignment: .leading, horizontalSpacing: DS.spacingL, verticalSpacing: DS.spacing) {
                row("App") {
                    HStack(spacing: DS.spacing) {
                        AppIconView(name: d.appName, size: 16)
                        Text(d.appName)
                    }
                }
                row("Date & Time") { Text(d.ts.formatted(date: .abbreviated, time: .shortened)) }
                row("Duration") { Text(formatDuration(d.durationSec)) }
                row("Words") { Text("\(wordCount(d.clean))") }
                row("Mode") { Text(modeName) }
                row("Status") { Text(statusName) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DS.spacing)
        }
    }

    private func row<V: View>(_ label: String, @ViewBuilder _ value: () -> V) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            value()
        }
    }

    private var modeName: String {
        switch d.mode { case "loud": return "Loud"; case "ai": return "AI"; default: return "Dictation" }
    }
    private var statusName: String {
        switch d.status { case "failed": return "Failed"; case "cancelled": return "Cancelled"; default: return "Transcribed" }
    }
}

// MARK: - Audio player

@MainActor
final class AudioPlayerModel: ObservableObject {
    @Published var isPlaying = false
    @Published var current: TimeInterval = 0
    @Published var duration: TimeInterval
    @Published var bars: [Float] = []
    private var player: AVAudioPlayer?
    private var timer: Timer?

    init(url: URL, fallbackDuration: TimeInterval) {
        duration = fallbackDuration
        player = try? AVAudioPlayer(contentsOf: url)
        player?.prepareToPlay()
        if let p = player, p.duration > 0 { duration = p.duration }
        Task { [weak self] in
            let b = await Task.detached(priority: .utility) { Self.loadBars(url: url, count: 120) }.value
            self?.bars = b
        }
    }

    func toggle() {
        guard let p = player else { return }
        if p.isPlaying { p.pause(); isPlaying = false; timer?.invalidate(); timer = nil }
        else {
            if p.currentTime >= p.duration - 0.05 { p.currentTime = 0 }
            p.play(); isPlaying = true
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] t in
                guard let self else { t.invalidate(); return }
                MainActor.assumeIsolated { self.tick() }
            }
        }
    }

    func seek(_ t: TimeInterval) {
        player?.currentTime = min(max(0, t), duration)
        current = player?.currentTime ?? t
    }

    func stop() {
        player?.stop(); timer?.invalidate(); timer = nil; isPlaying = false
    }

    private func tick() {
        guard let p = player else { return }
        current = p.currentTime
        if !p.isPlaying { isPlaying = false; timer?.invalidate(); timer = nil; if p.currentTime == 0 { current = duration } }
    }

    /// 16-bit PCM mono WAV with a 44-byte header → peak per bucket, normalised 0...1.
    nonisolated static func loadBars(url: URL, count: Int) -> [Float] {
        guard let data = try? Data(contentsOf: url), data.count > 44 + count * 2 else { return [] }
        let n = (data.count - 44) / 2
        let per = max(1, n / count)
        var out = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            let base = raw.baseAddress!.advanced(by: 44)
            for b in 0..<count {
                var peak: Int32 = 0
                let start = b * per, end = min(n, start + per)
                var i = start
                while i < end {
                    let v = Int32(base.loadUnaligned(fromByteOffset: i * 2, as: Int16.self).littleEndian)
                    peak = max(peak, abs(v))
                    i += 1
                }
                out[b] = Float(peak) / 32768
            }
        }
        let m = out.max() ?? 0
        return m > 0 ? out.map { $0 / m } : out
    }
}

struct AudioPlayerView: View {
    @StateObject private var model: AudioPlayerModel

    init(url: URL, fallbackDuration: TimeInterval) {
        _model = StateObject(wrappedValue: AudioPlayerModel(url: url, fallbackDuration: fallbackDuration))
    }

    var body: some View {
        GroupBox {
            VStack(spacing: DS.spacing) {
                WaveformView(bars: model.bars,
                             progress: model.duration > 0 ? model.current / model.duration : 0) { f in
                    model.seek(f * model.duration)
                }
                .frame(height: 48)

                HStack(spacing: DS.spacing) {
                    Button { model.toggle() } label: {
                        Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.large)
                    .help(model.isPlaying ? "Pause" : "Play")

                    Text(formatDuration(model.current)).monospacedDigit()
                        .font(.caption).foregroundStyle(.secondary)
                    Slider(value: Binding(get: { model.current }, set: { model.seek($0) }),
                           in: 0...max(model.duration, 0.1))
                        .controlSize(.small)
                    Text(formatDuration(model.duration)).monospacedDigit()
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(DS.spacing)
        }
        .onDisappear { model.stop() }
    }
}

struct WaveformView: View {
    var bars: [Float]
    var progress: Double
    var onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                guard !bars.isEmpty else { return }
                let n = bars.count
                let slot = size.width / CGFloat(n)
                let w = max(1, slot * 0.6)
                for (i, v) in bars.enumerated() {
                    let h = max(2, CGFloat(v) * size.height)
                    let rect = CGRect(x: CGFloat(i) * slot + (slot - w) / 2,
                                      y: (size.height - h) / 2, width: w, height: h)
                    let played = Double(i) / Double(n) < progress
                    ctx.fill(Path(roundedRect: rect, cornerRadius: w / 2),
                             with: played ? .style(.tint) : .color(.secondary.opacity(0.35)))
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                onSeek(min(max(0, g.location.x / geo.size.width), 1))
            })
        }
    }
}
