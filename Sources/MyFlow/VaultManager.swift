import Foundation

/// Scaffolds the Obsidian "Clients" vault: folder-per-client with templates.
/// Granola auto-sync is configured by the user inside Obsidian (see README
/// written into the vault); everything else is manual paste by design.
enum VaultManager {

    static func clientsRoot(_ baseURL: URL) -> URL {
        baseURL.appendingPathComponent("Clients", isDirectory: true)
    }

    /// Creates the vault skeleton (Clients/ + README) if missing.
    @discardableResult
    static func ensureVaultScaffold(baseURL: URL) -> Bool {
        let fm = FileManager.default
        let root = clientsRoot(baseURL)
        do {
            if !fm.fileExists(atPath: root.path) {
                try fm.createDirectory(at: root, withIntermediateDirectories: true)
            }
            let readme = baseURL.appendingPathComponent("README - My Flow.md")
            if !fm.fileExists(atPath: readme.path) {
                try vaultReadme().write(to: readme, atomically: true, encoding: .utf8)
            }
            mflog("Vault scaffold ready at \(root.path)")
            return true
        } catch {
            mflog("Vault scaffold FAILED: \(error.localizedDescription)")
            return false
        }
    }

    /// Creates Clients/<name>/ with client.md, meetings/, chats/, log.md.
    @discardableResult
    static func addNewClient(baseURL: URL, name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let fm = FileManager.default
        let dir = clientsRoot(baseURL).appendingPathComponent(trimmed, isDirectory: true)
        do {
            try fm.createDirectory(at: dir.appendingPathComponent("meetings"),
                                   withIntermediateDirectories: true)
            try fm.createDirectory(at: dir.appendingPathComponent("chats"),
                                   withIntermediateDirectories: true)
            let clientMD = dir.appendingPathComponent("client.md")
            if !fm.fileExists(atPath: clientMD.path) {
                try templateClientMD(name: trimmed).write(to: clientMD, atomically: true, encoding: .utf8)
            }
            let logMD = dir.appendingPathComponent("log.md")
            if !fm.fileExists(atPath: logMD.path) {
                try "# \(trimmed) Log\n\n- \(isoToday()): client folder created.\n"
                    .write(to: logMD, atomically: true, encoding: .utf8)
            }
            mflog("New client scaffolded: \(trimmed)")
            return true
        } catch {
            mflog("addNewClient FAILED for \(trimmed): \(error.localizedDescription)")
            return false
        }
    }

    static func templateClientMD(name: String) -> String {
        """
        ---
        name: \(name)
        aliases: []
        company: ""
        status: active
        comms: [email, slack]
        ---

        # \(name)

        ## Who
        <!-- key people, roles, how they like to communicate -->

        ## Current state
        <!-- what's live right now — My Flow reads this when writing for you -->

        ## Comms rules
        <!-- tone, sign-off, do/don't -->
        """
    }

    private static func vaultReadme() -> String {
        """
        # My Flow — Clients vault

        This vault feeds client context into My Flow's AI writing (fn+Space).

        ## Layout
        - `Clients/<Name>/client.md` — profile. Fill `aliases` (names you say
          out loud, e.g. [Jessica, Jess]) — matching runs on these.
        - `Clients/<Name>/meetings/` — Granola auto-sync target.
        - `Clients/<Name>/chats/` — paste Slack/WhatsApp/email snippets here.
        - `Clients/<Name>/log.md` — running "where things stand" notes.

        ## One-time Granola setup (manual, in Obsidian)
        1. Obsidian → Settings → Community plugins → Browse.
        2. Install "Granola Meetings Simple Sync" and enable it.
        3. Sign in (OAuth) and set its output folder to the client's
           `meetings/` folder (or a shared Meetings folder in this vault).
        Notes sync automatically every ~15 minutes afterwards.

        ## How matching works
        When you use fn+Space and mention a client name or alias, My Flow
        injects that client's `client.md`, recent `log.md`, and the newest
        meeting/chat notes into the AI prompt.
        """
    }

    private static func isoToday() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }
}
