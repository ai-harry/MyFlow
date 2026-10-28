import SwiftUI
import AppKit
import CoreAudio

/// Root of the native Settings scene.
struct SettingsRootView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            DictationSettingsTab()
                .tabItem { Label("Dictation", systemImage: "mic") }
            ModelsSettingsTab()
                .tabItem { Label("Models", systemImage: "cpu") }
            ShortcutsSettingsTab()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
            AdvancedSettingsTab()
                .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 520)
        .scenePadding()
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: settings.$launchAtLogin)
                    .onChange(of: settings.launchAtLogin) { settings.applyLoginItem() }
                Toggle("Always show in Dock", isOn: settings.$alwaysShowDockIcon)
                    .onChange(of: settings.alwaysShowDockIcon) { settings.applyDockIcon() }
            }
            Section("Flow Bar") {
                Toggle("Show Flow Bar", isOn: settings.$showFlowBar)
                    .onChange(of: settings.showFlowBar) {
                        if settings.showFlowBar { FlowBarController.shared.show() }
                        else { FlowBarController.shared.hide() }
                    }
                Picker("Appearance", selection: settings.$flowBarAppearance) {
                    Text("Follow system").tag("auto")
                    Text("Dark").tag("dark")
                    Text("Light").tag("light")
                }
                .onChange(of: settings.flowBarAppearance) {
                    FlowBarController.shared.applyAppearance()
                }
            }
            Section("Audio") {
                Toggle("Dictation sounds", isOn: settings.$soundsEnabled)
                Toggle("Mute other audio while recording", isOn: settings.$muteWhileRecording)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Dictation

private struct DictationSettingsTab: View {
    @ObservedObject var settings = AppSettings.shared
    @State private var devices: [AudioDevices.Device] = []
    @State private var selectedDevice: AudioDeviceID = 0
    @State private var styles: [StylePreset] = []
    @State private var newClientName = ""
    @State private var clientCreated = ""

    private let languages = ["en": "English", "es": "Spanish", "fr": "French", "de": "German",
                             "it": "Italian", "pt": "Portuguese", "nl": "Dutch", "pl": "Polish",
                             "ar": "Arabic", "zh": "Chinese", "ja": "Japanese", "ko": "Korean",
                             "vi": "Vietnamese", "el": "Greek"]

    var body: some View {
        Form {
            Section {
                Picker("Microphone", selection: $selectedDevice) {
                    ForEach(devices) { Text($0.name).tag($0.id) }
                    if !devices.contains(where: { $0.id == selectedDevice }) {
                        Text("System default").tag(selectedDevice)
                    }
                }
                .onChange(of: selectedDevice) {
                    if selectedDevice != AudioDevices.defaultInputID() {
                        AudioDevices.setDefaultInput(selectedDevice)
                    }
                }
                Toggle("Use Mac microphone with AirPods / Bluetooth", isOn: settings.$preferBuiltInMic)
                    .onChange(of: settings.preferBuiltInMic) { Engine.shared.rearmMic() }
                Text("Off: AirPods mic is used, so you can talk away from the Mac. On: Mac mic is used, which avoids the ~1 s Bluetooth switch delay.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Language", selection: settings.$language) {
                    ForEach(languages.sorted(by: { $0.value < $1.value }), id: \.key) { k, v in
                        Text(v).tag(k)
                    }
                }
            }
            Section("Cleanup") {
                Picker("Style", selection: settings.$activeStyleID) {
                    if !styles.contains(where: { Int($0.id) == settings.activeStyleID }) {
                        Text("Default").tag(settings.activeStyleID)
                    }
                    ForEach(styles) { Text($0.name).tag(Int($0.id)) }
                }
                Text("Cleanup removes fillers (um, uh, like). Edit styles in the main window.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Client vault") {
                LabeledContent("Folder") {
                    Text(settings.vaultPath.isEmpty ? "Not set" : settings.vaultPath)
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Button("Choose…") { chooseVault() }
                if !settings.vaultPath.isEmpty {
                    HStack {
                        TextField("New client name", text: $newClientName)
                        Button("New Client") {
                            let base = URL(fileURLWithPath: settings.vaultPath)
                            if VaultManager.addNewClient(baseURL: base, name: newClientName) {
                                clientCreated = newClientName
                                newClientName = ""
                            }
                        }
                        .disabled(newClientName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if !clientCreated.isEmpty {
                        Text("Created “\(clientCreated)”. Fill its client.md aliases so My Flow recognizes spoken names.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("Folder per client: client.md (profile and aliases), meetings/, chats/, log.md.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear(perform: refresh)
    }

    private func refresh() {
        devices = AudioDevices.inputs()
        selectedDevice = AudioDevices.defaultInputID()
        styles = Store.shared.styles()
    }

    private func chooseVault() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use as Vault"
        if panel.runModal() == .OK, let url = panel.url {
            settings.vaultPath = url.path
            _ = VaultManager.ensureVaultScaffold(baseURL: url)
        }
    }
}

// MARK: - Models

private struct ModelsSettingsTab: View {
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        Form {
            Section("API keys") {
                APIKeyRow(title: "Cohere", name: .cohere, current: settings.cohereKey)
                APIKeyRow(title: "OpenRouter", name: .openRouter, current: settings.openRouterKey)
                APIKeyRow(title: "Groq", name: .groq, current: settings.groqKey)
                Text("Keys are stored in ~/Library/Application Support/MyFlow/.env, readable only by you.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Models") {
                TextField("Cleanup model", text: settings.$cleanupModel)
                LabeledContent("Backup cleanup model", value: Services.cleanupBackupModel)
                TextField("AI command model", text: settings.$llmModel)
                TextField("ASR fallback model", text: settings.$asrFallbackModel)
            }
            Section("On-device") {
                LabeledContent("Local Parakeet") {
                    if LocalASR.isReady {
                        Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Text("Not loaded").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct APIKeyRow: View {
    let title: String
    let name: APIKeyName
    let current: String
    @State private var draft = ""
    @State private var saveFailed = false
    @State private var confirmRemove = false
    @FocusState private var focused: Bool

    private var placeholder: String {
        if current.isEmpty { return "Paste key" }
        return current.count > 12 ? "••••" + current.suffix(4) : "••••"
    }

    var body: some View {
        LabeledContent(title) {
            VStack(alignment: .trailing, spacing: 4) {
                HStack {
                    SecureField("", text: $draft, prompt: Text(placeholder))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .focused($focused)
                        .onSubmit(save)
                    Button("Save", action: save)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if !current.isEmpty {
                        Button("Remove", role: .destructive) { confirmRemove = true }
                    }
                    if current.isEmpty {
                        Label("Not set", systemImage: "xmark.circle").foregroundStyle(.secondary)
                    } else {
                        Label("Saved", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                }
                .labelStyle(.titleAndIcon)
                .font(.callout)
                if saveFailed {
                    Text("Could not save the key. Check permissions on the MyFlow folder.")
                        .font(.caption).foregroundStyle(.red)
                }
            }
        }
        .onChange(of: draft) { if draft.contains("\n") { save() } }
        .onChange(of: focused) { if !focused { save() } }
        .confirmationDialog("Remove \(title) key?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) {
                saveFailed = !AppSettings.shared.setAPIKey(name, "")
                draft = ""
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The key will be deleted from the .env file.")
        }
    }

    private func save() {
        let v = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return }
        if AppSettings.shared.setAPIKey(name, v) {
            saveFailed = false
            draft = ""
        } else {
            saveFailed = true
        }
    }
}

// MARK: - Shortcuts

private struct KeyCap: View {
    let label: String
    var body: some View {
        Text(label)
            .font(.system(.callout, design: .rounded, weight: .medium))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
    }
}

private struct ShortcutRow: View {
    let title: String
    let keys: [String]
    var note: String? = nil
    var body: some View {
        LabeledContent {
            HStack(spacing: 4) {
                ForEach(Array(keys.enumerated()), id: \.offset) { i, k in
                    if k == "+" { Text("+").foregroundStyle(.secondary) } else { KeyCap(label: k) }
                }
                if let note { Text(note).font(.caption).foregroundStyle(.secondary).padding(.leading, 4) }
            }
        } label: { Text(title) }
    }
}

private struct ShortcutsSettingsTab: View {
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                ShortcutRow(title: "Dictate (hold)", keys: ["fn"])
                ShortcutRow(title: "Hands-free", keys: ["fn", "+", "⌘"], note: "fn to stop")
                ShortcutRow(title: "Loud mode", keys: ["⇧", "+", "fn"], note: "fn to stop")
                ShortcutRow(title: "AI mode", keys: ["fn", "+", "Space"], note: "fn to stop")
                ShortcutRow(title: "Cancel", keys: ["esc"])
                Text("Set System Settings → Keyboard → “Press 🌐 key to” to Do Nothing. Loud mode adds noise-aware correction.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Transforms") {
                Toggle("Enable ⌥-number transform hotkeys", isOn: settings.$transformHotkeysEnabled)
                ShortcutRow(title: "Transform selection", keys: ["⌥", "+", "1–9"])
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Advanced

private struct AdvancedSettingsTab: View {
    var body: some View {
        Form {
            Section("Files") {
                Button("Open Data Folder") {
                    NSWorkspace.shared.open(AppSettings.supportDir)
                }
                Button("Open Debug Log") {
                    let url = AppSettings.supportDir.appendingPathComponent("debug.log")
                    if FileManager.default.fileExists(atPath: url.path) {
                        NSWorkspace.shared.open(url)
                    } else {
                        NSWorkspace.shared.activateFileViewerSelecting([AppSettings.supportDir])
                    }
                }
            }
            Section("Permissions") {
                Button("Grant Screen Recording (for AI screen context)") {
                    _ = Screenshot.ensurePermission()
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}
