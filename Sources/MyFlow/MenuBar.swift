import AppKit
import Combine
import CoreAudio

/// Menu-bar status item: template icon that reflects Engine.phase, and a menu
/// rebuilt every time it opens.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let openMain: () -> Void
    private let openSettings: () -> Void
    private var cancellable: AnyCancellable?
    private var lastDictationText = ""

    init(openMain: @escaping () -> Void, openSettings: @escaping () -> Void) {
        self.openMain = openMain
        self.openSettings = openSettings
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        updateIcon(Engine.shared.phase)
        cancellable = Engine.shared.$phase
            .receive(on: DispatchQueue.main)
            .sink { [weak self] phase in self?.updateIcon(phase) }
    }

    private func isRecording(_ p: Engine.Phase) -> Bool {
        switch p {
        case .ptt, .latched, .loud, .ai: return true
        default: return false
        }
    }

    private func updateIcon(_ phase: Engine.Phase) {
        let name = isRecording(phase) ? "waveform.circle.fill" : "waveform"
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "My Flow")
        img?.isTemplate = true
        statusItem.button?.image = img
    }

    private func statusText() -> String {
        switch Engine.shared.phase {
        case .idle, .flash, .suggestion: return "Ready — hold fn to dictate"
        case .ptt, .latched, .loud, .ai: return "Recording…"
        case .processing: return "Transcribing…"
        case .error(let m): return "Error: \(m)"
        }
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let status = NSMenuItem(title: statusText(), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        if let last = Store.shared.recentDictations(limit: 20, search: "")
            .first(where: { $0.status == "ok" && !$0.clean.isEmpty }) {
            lastDictationText = last.clean
            let flat = last.clean.replacingOccurrences(of: "\n", with: " ")
            let shown = flat.count > 50 ? String(flat.prefix(50)) + "…" : flat
            let preview = NSMenuItem(title: shown, action: nil, keyEquivalent: "")
            preview.isEnabled = false
            menu.addItem(preview)
            let copy = NSMenuItem(title: "Copy Last Dictation", action: #selector(copyLast), keyEquivalent: "c")
            copy.keyEquivalentModifierMask = [.command, .shift]
            copy.target = self
            menu.addItem(copy)
        }

        menu.addItem(.separator())

        let micItem = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        let sub = NSMenu(title: "Microphone")
        sub.autoenablesItems = false
        let current = AudioDevices.defaultInputID()
        for d in AudioDevices.inputs() {
            let it = NSMenuItem(title: d.name, action: #selector(selectMic(_:)), keyEquivalent: "")
            it.target = self
            it.tag = Int(d.id)
            it.state = d.id == current ? .on : .off
            sub.addItem(it)
        }
        if sub.items.isEmpty {
            let none = NSMenuItem(title: "No input devices", action: nil, keyEquivalent: "")
            none.isEnabled = false
            sub.addItem(none)
        }
        micItem.submenu = sub
        menu.addItem(micItem)

        menu.addItem(.separator())
        let open = NSMenuItem(title: "Open My Flow", action: #selector(openMainAction), keyEquivalent: "o")
        open.target = self
        menu.addItem(open)
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettingsAction), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit My Flow", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
    }

    // MARK: Actions

    @objc private func copyLast() {
        guard !lastDictationText.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(lastDictationText, forType: .string)
    }

    @objc private func selectMic(_ sender: NSMenuItem) {
        AudioDevices.setDefaultInput(AudioDeviceID(sender.tag))
    }

    @objc private func openMainAction() { openMain() }
    @objc private func openSettingsAction() { openSettings() }
}
