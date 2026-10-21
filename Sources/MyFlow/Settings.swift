import Foundation
import SwiftUI
import ServiceManagement

enum APIKeyName: String, CaseIterable {
    case cohere, openRouter, groq
    var account: String {
        switch self {
        case .cohere: return "COHERE_API_KEY"
        case .openRouter: return "OPENROUTER_API_KEY"
        case .groq: return "GROQ_API_KEY"
        }
    }
}

/// App-wide settings. Persisted in UserDefaults; secrets come from the .env
/// file in ~/Library/Application Support/MyFlow/.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    static let supportDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent("MyFlow", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    // Secrets live in the .env file (mode 0600). Not the Keychain: dev builds are
    // self-signed, so every rebuild re-triggers a blocking Keychain access prompt.
    // Backed by lock-protected storage so background async code can read them
    // safely; writes notify SwiftUI on the main thread.
    private let keyLock = NSLock()
    private var keyStore: [APIKeyName: String] = [:]
    private func key(_ n: APIKeyName) -> String {
        keyLock.lock(); defer { keyLock.unlock() }
        return keyStore[n] ?? ""
    }
    var cohereKey: String { key(.cohere) }
    var openRouterKey: String { key(.openRouter) }
    var groqKey: String { key(.groq) }

    /// Set by the app shell while the main window is visible.
    var mainWindowVisible = false
    /// Set by the app shell while the Settings window is visible.
    var settingsWindowVisible = false

    // Persisted preferences
    @AppStorage("language") var language = "en"
    @AppStorage("cleanupEnabled") var cleanupEnabled = true
    @AppStorage("llmModel") var llmModel = "moonshotai/kimi-k3"
    @AppStorage("cleanupModel") var cleanupModel = "meta-llama/llama-3.3-70b-instruct"
    @AppStorage("muteWhileRecording") var muteWhileRecording = true
    @AppStorage("vaultPath") var vaultPath = ""
    @AppStorage("asrFallbackModel") var asrFallbackModel = "openai/whisper-large-v3"
    @AppStorage("showFlowBar") var showFlowBar = true
    /// "auto" (follow system) | "dark" | "light" — see FlowBarController.
    @AppStorage("flowBarAppearance") var flowBarAppearance = "auto"
    @AppStorage("alwaysShowDockIcon") var alwaysShowDockIcon = false
    var showDockIcon: Bool {
        get { alwaysShowDockIcon }
        set { alwaysShowDockIcon = newValue }
    }
    @AppStorage("soundsEnabled") var soundsEnabled = true
    @AppStorage("launchAtLogin") var launchAtLogin = true
    @AppStorage("transformHotkeysEnabled") var transformHotkeysEnabled = true
    @AppStorage("activeStyleID") var activeStyleID = 0
    @AppStorage("maxSeconds") var maxSeconds = 180

    private init() { loadEnv() }

    private static var envURL: URL { supportDir.appendingPathComponent(".env") }

    private func assign(_ name: APIKeyName, _ value: String) {
        keyLock.lock()
        let changed = keyStore[name] != value
        keyStore[name] = value
        keyLock.unlock()
        guard changed else { return }
        if Thread.isMainThread { objectWillChange.send() }
        else { DispatchQueue.main.async { [weak self] in self?.objectWillChange.send() } }
    }

    /// Parses one .env line into (key, value); nil for blanks, comments, malformed.
    private static func parseEnvLine(_ raw: String) -> (key: String, value: String)? {
        var line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") { return nil }
        if line.hasPrefix("export ") { line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
        guard let eq = line.firstIndex(of: "=") else { return nil }
        let k = line[..<eq].trimmingCharacters(in: .whitespaces)
        var v = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        if v.count >= 2, let f = v.first, let l = v.last, f == l, f == "\"" || f == "'" {
            v = String(v.dropFirst().dropLast())
        }
        return k.isEmpty ? nil : (k, v)
    }

    /// Saves to the .env file (empty string removes it) and updates the in-memory value.
    /// Other lines (comments, other keys) are preserved. Returns false if the write failed.
    @discardableResult
    func setAPIKey(_ name: APIKeyName, _ value: String) -> Bool {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = (try? String(contentsOf: Self.envURL, encoding: .utf8)) ?? ""
        var lines = text.components(separatedBy: .newlines).filter { line in
            Self.parseEnvLine(line)?.key != name.account
        }
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        if !v.isEmpty { lines.append("\(name.account)=\(v)") }
        let out = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        do {
            try out.write(to: Self.envURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.envURL.path)
        } catch {
            mflog("could not save \(name.account): \(error.localizedDescription)")
            return false
        }
        assign(name, v)
        return true
    }

    func loadEnv() {
        guard let text = try? String(contentsOf: Self.envURL, encoding: .utf8) else { return }
        for line in text.components(separatedBy: .newlines) {
            guard let (key, val) = Self.parseEnvLine(line) else { continue }
            switch key {
            case "COHERE_API_KEY": assign(.cohere, val)
            case "OPENROUTER_API_KEY": assign(.openRouter, val)
            case "GROQ_API_KEY": assign(.groq, val)
            case "OPENROUTER_MODEL": if UserDefaults.standard.string(forKey: "llmModel") == nil { llmModel = val }
            default: break
            }
        }
    }

    func applyLoginItem() {
        do {
            if launchAtLogin { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            mflog("login item error: \(error)")
        }
    }

    /// Called at launch: registers the login item when the setting is on but
    /// macOS doesn't have it yet (first run, or the app was reinstalled).
    /// If the user switched it off in System Settings → Login Items, macOS
    /// reports .requiresApproval and we leave that choice alone.
    func syncLoginItem() {
        let status = SMAppService.mainApp.status
        if launchAtLogin, status == .notRegistered || status == .notFound {
            applyLoginItem()
        }
        mflog("login item: \(launchAtLogin ? "on" : "off"), status \(SMAppService.mainApp.status.rawValue)")
    }

    func applyDockIcon() {
        NSApp.setActivationPolicy(alwaysShowDockIcon || mainWindowVisible || settingsWindowVisible ? .regular : .accessory)
    }
}
