import Foundation

struct ClientProfile {
    var name: String
    var aliases: [String]
    var company: String
    var status: String
    var folderURL: URL
}

/// Scans the Clients vault, parses profiles, matches spoken names, and
/// assembles per-client context for the AI prompt. Lazy: scans on first use,
/// rescans when any client.md changes.
@MainActor
final class ClientContext {
    static let shared = ClientContext()

    private var profiles: [ClientProfile] = []
    private var lastScan: Date = .distantPast
    private var scannedSignature: String = ""

    private init() {}

    // MARK: - matching

    func matchClients(instruction: String) async -> [ClientProfile] {
        guard let base = vaultBase() else { return [] }
        refreshIfStale(base: base)
        let words = Set(instruction.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty })
        return profiles.filter { p in
            var names = [p.name] + p.aliases
            if !p.company.isEmpty { names.append(p.company) }
            return names.contains { candidate in
                let tokens = candidate.lowercased()
                    .components(separatedBy: CharacterSet.alphanumerics.inverted)
                    .filter { !$0.isEmpty }
                // every token of the candidate name appears as a whole word
                return !tokens.isEmpty && tokens.allSatisfy { words.contains($0) }
            }
        }
    }

    /// Assembles a token-budgeted context block for matched clients:
    /// client.md body + tail of log.md + newest meeting + newest chat note.
    func contextBlock(for clients: [ClientProfile], maxChars: Int = 9000) -> String {
        var out = ""
        let per = maxChars / max(1, clients.count)
        for c in clients {
            var block = "## Client: \(c.name)\n"
            block += read(c.folderURL.appendingPathComponent("client.md"), limit: per / 3) ?? ""
            if let log = read(c.folderURL.appendingPathComponent("log.md"), limit: per / 4, tail: true) {
                block += "\n### Recent log\n" + log
            }
            for sub in ["meetings", "chats"] {
                if let newest = newestFile(in: c.folderURL.appendingPathComponent(sub)),
                   let body = read(newest, limit: per / 4, tail: true) {
                    block += "\n### Latest \(sub) note (\(newest.lastPathComponent))\n" + body
                }
            }
            out += block + "\n\n"
        }
        return String(out.prefix(maxChars))
    }

    // MARK: - scanning

    private func vaultBase() -> URL? {
        let path = AppSettings.shared.vaultPath
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    private func refreshIfStale(base: URL) {
        let sig = currentSignature(base: base)
        if profiles.isEmpty || sig != scannedSignature {
            scanVault(base: base)
            scannedSignature = sig
        }
    }

    /// Cheap staleness signature: every client.md path + mtime.
    private func currentSignature(base: URL) -> String {
        let root = VaultManager.clientsRoot(base)
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return "" }
        var parts: [String] = []
        for f in folders where f.hasDirectoryPath {
            let md = f.appendingPathComponent("client.md")
            if let attrs = try? fm.attributesOfItem(atPath: md.path),
               let mtime = attrs[.modificationDate] as? Date {
                parts.append("\(md.path):\(mtime.timeIntervalSince1970)")
            }
        }
        return parts.sorted().joined(separator: "|")
    }

    private func scanVault(base: URL) {
        let root = VaultManager.clientsRoot(base)
        let fm = FileManager.default
        var found: [ClientProfile] = []
        if let folders = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            for folder in folders where folder.hasDirectoryPath {
                let md = folder.appendingPathComponent("client.md")
                guard let text = try? String(contentsOf: md, encoding: .utf8) else { continue }
                let fm2 = frontmatter(of: text)
                found.append(ClientProfile(
                    name: fm2["name"] ?? folder.lastPathComponent,
                    aliases: list(fm2["aliases"]),
                    company: fm2["company"] ?? "",
                    status: fm2["status"] ?? "",
                    folderURL: folder))
            }
        }
        profiles = found.sorted { $0.name < $1.name }
        lastScan = Date()
        mflog("ClientContext: scanned \(profiles.count) clients")
    }

    /// Minimal, restricted frontmatter parser (key: value lines between ---).
    /// Deliberately NOT a full YAML parser — only flat scalar/inline-list keys.
    private func frontmatter(of text: String) -> [String: String] {
        var out: [String: String] = [:]
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return out }
        for line in lines.dropFirst() {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t == "---" { break }
            guard let colon = t.firstIndex(of: ":") else { continue }
            let key = String(t[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let val = String(t[t.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            out[key] = val.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return out
    }

    /// Parses `[a, b]` or `a, b` into a list.
    private func list(_ raw: String?) -> [String] {
        guard var s = raw else { return [] }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return s.split(separator: ",")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) }
            .filter { !$0.isEmpty }
    }

    // MARK: - file helpers

    private func read(_ url: URL, limit: Int, tail: Bool = false) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        if text.count <= limit { return text }
        return tail ? String(text.suffix(limit)) : String(text.prefix(limit))
    }

    private func newestFile(in dir: URL) -> URL? {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        return files
            .filter { $0.pathExtension == "md" }
            .max { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da < db
            }
    }
}
