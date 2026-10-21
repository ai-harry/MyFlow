import AppKit
import Combine
import SwiftUI

/// The floating Flow Bar HUD. Non-activating, joins all Spaces, and follows the
/// mouse pointer's screen each time a recording starts. Mouse events pass
/// straight through except while the dictionary suggestion is showing.
final class FlowBarController {
    static let shared = FlowBarController()
    private var panel: NSPanel?
    private var cancellables = Set<AnyCancellable>()

    private let panelSize = NSSize(width: 520, height: 120)

    func show() {
        if panel == nil { build() }
        applyAppearance()
        reposition()
        panel?.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }

    /// Light/dark is driven by the PANEL's appearance, which SwiftUI reads as
    /// `colorScheme` inside the hosting view.
    func applyAppearance() {
        guard let panel else { return }
        switch AppSettings.shared.flowBarAppearance {
        case "dark":  panel.appearance = NSAppearance(named: .darkAqua)
        case "light": panel.appearance = NSAppearance(named: .aqua)
        default:      panel.appearance = nil
        }
    }

    // MARK: Screen placement

    private func targetScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        if let s = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) { return s }
        if let s = NSApp.keyWindow?.screen { return s }
        return NSScreen.main ?? NSScreen.screens.first
    }

    /// Bottom-centre of the target screen's visible frame (respects the Dock).
    private func reposition() {
        guard let panel, let screen = targetScreen() else { return }
        let vf = screen.visibleFrame
        let origin = NSPoint(x: vf.midX - panelSize.width / 2, y: vf.minY + 6)
        panel.setFrame(NSRect(origin: origin, size: panelSize), display: false)
    }

    private func build() {
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: panelSize),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.ignoresMouseEvents = true          // never blocks clicks
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        let host = PassthroughHostingView(rootView: FlowBarView())
        host.sizingOptions = []
        p.contentView = host
        panel = p

        // Re-evaluate the screen whenever we leave idle; enable clicks only
        // for the suggestion buttons.
        var previous: Engine.Phase = .idle
        MainActor.assumeIsolated {
            Engine.shared.$phase
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] phase in
                    guard let self, let panel = self.panel else { return }
                    if previous == .idle, phase != .idle { self.reposition() }
                    if case .suggestion = phase { panel.ignoresMouseEvents = false }
                    else { panel.ignoresMouseEvents = true }
                    previous = phase
                }
                .store(in: &cancellables)
        }
        applyAppearance()
        reposition()
        p.orderFrontRegardless()
    }
}

/// Hosting view that ignores clicks on transparent areas so they reach windows behind.
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let v = super.hitTest(point)
        return v === self ? nil : v
    }
}

// MARK: - Bar

struct FlowBarView: View {
    @ObservedObject var engine = Engine.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Namespace private var ns

    private static let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)

    private var morph: Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.35, dampingFraction: 1.0)
    }
    private var growIn: Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.38, dampingFraction: 0.82)
    }
    private var animation: Animation {
        engine.phase == .idle ? morph : growIn
    }

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            GlassEffectContainer(spacing: 20) {
                bar
            }
            .animation(animation, value: engine.phase)
            .animation(morph, value: engine.micWarming)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 4)
    }

    private var isError: Bool { if case .error = engine.phase { return true } else { return false } }

    private var glass: Glass {
        isError ? .regular.tint(.red.opacity(0.35)) : .regular
    }

    @ViewBuilder
    private var bar: some View {
        let inner = content
            .transition(.opacity)
            .id(stateKey)
        if reduceTransparency {
            inner
                .background(Self.shape.fill(Color(nsColor: .windowBackgroundColor)))
                .overlay(Self.shape.strokeBorder(.separator, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
        } else {
            inner
                .glassEffect(glass, in: Self.shape)
                .glassEffectID("bar", in: ns)
                .overlay { if case .processing = engine.phase, !reduceMotion { Shimmer(shape: Self.shape) } }
        }
    }

    /// Identity of the visual state: content cross-fades only when this changes.
    private var stateKey: Int {
        switch engine.phase {
        case .idle: return 0
        case .ptt, .latched, .loud, .ai: return 1
        case .processing: return 2
        case .flash: return 3
        case .error: return 4
        case .suggestion: return 5
        }
    }

    @ViewBuilder
    private var content: some View {
        switch engine.phase {
        case .idle:
            Capsule()
                .fill(.secondary.opacity(0.9))
                .frame(width: 26, height: 5)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
        case .ptt:
            RecordingContent(levels: engine.levels, icon: nil, label: nil, warming: engine.micWarming)
        case .latched:
            RecordingContent(levels: engine.levels, icon: "hand.raised.fill", label: "Hands-free", warming: engine.micWarming)
        case .loud:
            RecordingContent(levels: engine.levels, icon: "speaker.wave.3.fill", label: "Loud", warming: engine.micWarming)
        case .ai:
            RecordingContent(levels: engine.levels, icon: "sparkles", label: "AI", warming: engine.micWarming)
        case .processing(let label):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        case .flash(let text):
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.green)
                Text(text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: 420, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16).padding(.vertical, 10)
        case .error(let text):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.red)
                Text(text)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: 420, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16).padding(.vertical, 10)
        case .suggestion(let word):
            HStack(spacing: 10) {
                Image(systemName: "character.book.closed.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.accentColor)
                Text("Add “\(word)” to dictionary?")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Add") { engine.acceptSuggestion() }
                    .buttonStyle(.borderedProminent)
                Button("Dismiss") { engine.dismissSuggestion() }
                    .buttonStyle(.bordered)
            }
            .controlSize(.small)
            .frame(maxWidth: 460)
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
    }
}

// MARK: - Pieces

/// Centred rounded-bar waveform driven by live RMS levels.
private struct RecordingContent: View {
    let levels: [Float]
    let icon: String?
    let label: String?
    let warming: Bool

    var body: some View {
        HStack(spacing: 8) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            HStack(spacing: 2.5) {
                ForEach(Array(levels.enumerated()), id: \.offset) { i, lvl in
                    // Taper the edges so the waveform reads as a soft lozenge.
                    let t = Double(i) / Double(max(1, levels.count - 1))
                    let taper = 0.55 + 0.45 * sin(t * .pi)
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: 2.5, height: max(3, min(26, CGFloat(lvl) * 26 * taper)))
                }
            }
            .frame(height: 26)
            .opacity(warming ? 0.35 : 1)
            .animation(.smooth(duration: 0.1), value: levels)
            if warming {
                Text("Connecting mic…")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            } else if let label {
                Text(label)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
    }
}

/// Soft highlight sweeping across the capsule while processing.
private struct Shimmer<S: InsettableShape>: View {
    let shape: S

    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let phase = CGFloat((t.truncatingRemainder(dividingBy: 1.6)) / 1.6)
            GeometryReader { geo in
                LinearGradient(colors: [.clear, .white.opacity(0.28), .clear],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: geo.size.width * 0.5)
                    .offset(x: -geo.size.width * 0.5 + phase * geo.size.width * 1.5)
            }
            .clipShape(shape)
            .blendMode(.plusLighter)
            .allowsHitTesting(false)
        }
    }
}
