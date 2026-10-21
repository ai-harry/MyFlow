import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct Dictation: Identifiable {
    var id: Int64
    var ts: Date
    var raw: String
    var clean: String
    var appName: String
    var durationSec: Double
    var mode: String      // "dictation" | "loud" | "ai"
    var status: String    // "ok" | "failed"
    var audioPath: String // saved WAV for failed entries, else ""
}

struct VocabWord: Identifiable { var id: Int64; var word: String }
struct Snippet: Identifiable { var id: Int64; var trigger: String; var expansion: String }
struct StylePreset: Identifiable { var id: Int64; var name: String; var prompt: String }
struct Transform: Identifiable { var id: Int64; var slot: Int; var name: String; var prompt: String }
struct Note: Identifiable { var id: Int64; var title: String; var body: String; var updated: Date }

struct DayCount: Identifiable { var id: String { day }; var day: String; var words: Int }
struct AppUsage: Identifiable { var id: String { app }; var app: String; var count: Int }

/// Tiny SQLite wrapper — no dependencies, single serial queue.
final class Store {
    static let shared = Store()
    private var db: OpaquePointer?
    private let q = DispatchQueue(label: "myflow.store")

    private init() {
        let path = AppSettings.supportDir.appendingPathComponent("myflow.db").path
        sqlite3_open(path, &db)
        exec("""
        CREATE TABLE IF NOT EXISTS dictations(
          id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL, raw TEXT, clean TEXT,
          app TEXT, duration REAL, mode TEXT DEFAULT 'dictation');
        CREATE TABLE IF NOT EXISTS vocab(id INTEGER PRIMARY KEY AUTOINCREMENT, word TEXT UNIQUE);
        CREATE TABLE IF NOT EXISTS snippets(id INTEGER PRIMARY KEY AUTOINCREMENT, trigger TEXT, expansion TEXT);
        CREATE TABLE IF NOT EXISTS styles(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, prompt TEXT);
        CREATE TABLE IF NOT EXISTS transforms(id INTEGER PRIMARY KEY AUTOINCREMENT, slot INT, name TEXT, prompt TEXT);
        CREATE TABLE IF NOT EXISTS notes(id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT, body TEXT, updated REAL);
        """)
        // migrations (ignore "duplicate column" errors on re-run)
        exec("ALTER TABLE dictations ADD COLUMN status TEXT DEFAULT 'ok'")
        exec("ALTER TABLE dictations ADD COLUMN audio TEXT DEFAULT ''")
        seedDefaults()
    }

    private func exec(_ sql: String) {
        q.sync { sqlite3_exec(db, sql, nil, nil, nil) }
    }

    private func seedDefaults() {
        if styles().isEmpty {
            addStyle(name: "Default", prompt: "Natural written English. Keep the speaker's tone.")
            addStyle(name: "Professional", prompt: "Polished, concise business writing. No slang.")
            addStyle(name: "Casual", prompt: "Relaxed, friendly tone. Contractions are fine.")
        }
        if transforms().isEmpty {
            addTransform(slot: 1, name: "Polish", prompt: "Improve clarity and conciseness without changing meaning.")
            addTransform(slot: 2, name: "Prompt Engineer", prompt: "Rewrite this as a well-structured prompt for an AI model.")
        }
    }

    // MARK: dictations
    func logDictation(raw: String, clean: String, app: String, duration: Double,
                      mode: String, status: String = "ok", audio: String = "") {
        q.sync {
            var s: OpaquePointer?
            sqlite3_prepare_v2(db, "INSERT INTO dictations(ts,raw,clean,app,duration,mode,status,audio) VALUES(?,?,?,?,?,?,?,?)", -1, &s, nil)
            sqlite3_bind_double(s, 1, Date().timeIntervalSince1970)
            sqlite3_bind_text(s, 2, raw, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(s, 3, clean, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(s, 4, app, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(s, 5, duration)
            sqlite3_bind_text(s, 6, mode, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(s, 7, status, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(s, 8, audio, -1, SQLITE_TRANSIENT)
            sqlite3_step(s); sqlite3_finalize(s)
        }
    }

    /// Updates a dictation with a (re-)transcription result. The audio path is
    /// kept so the row stays retryable until pruning removes the file.
    func resolveDictation(id: Int64, raw: String, clean: String) {
        run("UPDATE dictations SET raw=?, clean=?, status='ok' WHERE id=?",
            [raw, clean, id])
    }

    func recentDictations(limit: Int = 200, search: String = "") -> [Dictation] {
        q.sync {
            var out: [Dictation] = []
            var s: OpaquePointer?
            let sql = search.isEmpty
              ? "SELECT id,ts,raw,clean,app,duration,mode,status,audio FROM dictations ORDER BY ts DESC LIMIT ?"
              : "SELECT id,ts,raw,clean,app,duration,mode,status,audio FROM dictations WHERE clean LIKE ? ESCAPE '\\' OR raw LIKE ? ESCAPE '\\' ORDER BY ts DESC LIMIT ?"
            sqlite3_prepare_v2(db, sql, -1, &s, nil)
            if search.isEmpty { sqlite3_bind_int(s, 1, Int32(limit)) }
            else {
                let esc = search.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "%", with: "\\%")
                    .replacingOccurrences(of: "_", with: "\\_")
                sqlite3_bind_text(s, 1, "%\(esc)%", -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(s, 2, "%\(esc)%", -1, SQLITE_TRANSIENT)
                sqlite3_bind_int(s, 3, Int32(limit))
            }
            while sqlite3_step(s) == SQLITE_ROW {
                out.append(Dictation(
                    id: sqlite3_column_int64(s, 0),
                    ts: Date(timeIntervalSince1970: sqlite3_column_double(s, 1)),
                    raw: String(cString: sqlite3_column_text(s, 2)),
                    clean: String(cString: sqlite3_column_text(s, 3)),
                    appName: String(cString: sqlite3_column_text(s, 4)),
                    durationSec: sqlite3_column_double(s, 5),
                    mode: String(cString: sqlite3_column_text(s, 6)),
                    status: sqlite3_column_text(s, 7).map { String(cString: $0) } ?? "ok",
                    audioPath: sqlite3_column_text(s, 8).map { String(cString: $0) } ?? ""))
            }
            sqlite3_finalize(s)
            return out
        }
    }

    /// Deletes a dictation row (callers remove the audio file themselves).
    @discardableResult
    func deleteDictation(id: Int64) -> Bool {
        q.sync {
            var s: OpaquePointer?
            guard sqlite3_prepare_v2(db, "DELETE FROM dictations WHERE id=?", -1, &s, nil) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(s) }
            sqlite3_bind_int64(s, 1, id)
            return sqlite3_step(s) == SQLITE_DONE && sqlite3_changes(db) > 0
        }
    }

    // MARK: stats for Insights
    struct Stats { var totalWords: Int; var avgWPM: Double; var streakDays: Int; var totalCount: Int }

    func stats() -> Stats {
        q.sync {
            var s: OpaquePointer?
            var totalWords = 0, count = 0
            var wpmSum = 0.0, wpmN = 0.0
            sqlite3_prepare_v2(db, "SELECT clean,duration FROM dictations", -1, &s, nil)
            while sqlite3_step(s) == SQLITE_ROW {
                let clean = String(cString: sqlite3_column_text(s, 0))
                let dur = sqlite3_column_double(s, 1)
                let words = clean.split(separator: " ").count
                totalWords += words; count += 1
                if dur > 1 { wpmSum += Double(words) / (dur / 60.0); wpmN += 1 }
            }
            sqlite3_finalize(s)

            // streak: consecutive days ending today with >=1 dictation
            var days = Set<String>()
            sqlite3_prepare_v2(db, "SELECT DISTINCT date(ts,'unixepoch','localtime') FROM dictations WHERE status='ok' AND clean<>''", -1, &s, nil)
            while sqlite3_step(s) == SQLITE_ROW { days.insert(String(cString: sqlite3_column_text(s, 0))) }
            sqlite3_finalize(s)
            let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.calendar = Calendar(identifier: .gregorian)
            var streak = 0
            var d = Date()
            while days.contains(fmt.string(from: d)) {
                streak += 1
                d = Calendar.current.date(byAdding: .day, value: -1, to: d)!
            }
            return Stats(totalWords: totalWords, avgWPM: wpmN > 0 ? wpmSum / wpmN : 0,
                         streakDays: streak, totalCount: count)
        }
    }

    func wordsByDay(days: Int = 120) -> [DayCount] {
        q.sync {
            var out: [DayCount] = []
            var s: OpaquePointer?
            sqlite3_prepare_v2(db, """
              SELECT date(ts,'unixepoch','localtime') d,
                     SUM(LENGTH(clean)-LENGTH(REPLACE(clean,' ',''))+1)
              FROM dictations WHERE ts > ? AND status='ok' AND clean<>'' GROUP BY d ORDER BY d
              """, -1, &s, nil)
            sqlite3_bind_double(s, 1, Date().timeIntervalSince1970 - Double(days) * 86400)
            while sqlite3_step(s) == SQLITE_ROW {
                out.append(DayCount(day: String(cString: sqlite3_column_text(s, 0)),
                                    words: Int(sqlite3_column_int64(s, 1))))
            }
            sqlite3_finalize(s)
            return out
        }
    }

    /// Total words and recorded seconds for successful dictations in the last `days` days.
    func totals(days: Int) -> (words: Int, seconds: Double) {
        q.sync {
            var s: OpaquePointer?
            var words = 0, secs = 0.0
            sqlite3_prepare_v2(db, "SELECT clean,duration FROM dictations WHERE ts > ? AND status='ok'", -1, &s, nil)
            sqlite3_bind_double(s, 1, Date().timeIntervalSince1970 - Double(days) * 86400)
            while sqlite3_step(s) == SQLITE_ROW {
                words += String(cString: sqlite3_column_text(s, 0)).split(whereSeparator: { $0.isWhitespace }).count
                secs += sqlite3_column_double(s, 1)
            }
            sqlite3_finalize(s)
            return (words, secs)
        }
    }

    func appUsage() -> [AppUsage] {
        q.sync {
            var out: [AppUsage] = []
            var s: OpaquePointer?
            sqlite3_prepare_v2(db, "SELECT app, COUNT(*) c FROM dictations GROUP BY app ORDER BY c DESC LIMIT 8", -1, &s, nil)
            while sqlite3_step(s) == SQLITE_ROW {
                out.append(AppUsage(app: String(cString: sqlite3_column_text(s, 0)),
                                    count: Int(sqlite3_column_int64(s, 1))))
            }
            sqlite3_finalize(s)
            return out
        }
    }

    // MARK: simple CRUD helpers
    private func rows<T>(_ sql: String, _ map: (OpaquePointer?) -> T) -> [T] {
        q.sync {
            var out: [T] = []
            var s: OpaquePointer?
            sqlite3_prepare_v2(db, sql, -1, &s, nil)
            while sqlite3_step(s) == SQLITE_ROW { out.append(map(s)) }
            sqlite3_finalize(s)
            return out
        }
    }

    private func run(_ sql: String, _ binds: [Any]) {
        q.sync {
            var s: OpaquePointer?
            sqlite3_prepare_v2(db, sql, -1, &s, nil)
            for (i, b) in binds.enumerated() {
                let idx = Int32(i + 1)
                switch b {
                case let v as String: sqlite3_bind_text(s, idx, v, -1, SQLITE_TRANSIENT)
                case let v as Int: sqlite3_bind_int64(s, idx, Int64(v))
                case let v as Int64: sqlite3_bind_int64(s, idx, v)
                case let v as Double: sqlite3_bind_double(s, idx, v)
                default: break
                }
            }
            sqlite3_step(s); sqlite3_finalize(s)
        }
    }

    func vocab() -> [VocabWord] {
        rows("SELECT id,word FROM vocab ORDER BY word") {
            VocabWord(id: sqlite3_column_int64($0, 0), word: String(cString: sqlite3_column_text($0, 1)))
        }
    }
    func addVocab(_ w: String) { run("INSERT OR IGNORE INTO vocab(word) VALUES(?)", [w]) }
    func deleteVocab(_ id: Int64) { run("DELETE FROM vocab WHERE id=?", [id]) }

    func snippets() -> [Snippet] {
        rows("SELECT id,trigger,expansion FROM snippets ORDER BY trigger") {
            Snippet(id: sqlite3_column_int64($0, 0),
                    trigger: String(cString: sqlite3_column_text($0, 1)),
                    expansion: String(cString: sqlite3_column_text($0, 2)))
        }
    }
    func addSnippet(trigger: String, expansion: String) { run("INSERT INTO snippets(trigger,expansion) VALUES(?,?)", [trigger, expansion]) }
    func deleteSnippet(_ id: Int64) { run("DELETE FROM snippets WHERE id=?", [id]) }

    func styles() -> [StylePreset] {
        rows("SELECT id,name,prompt FROM styles ORDER BY id") {
            StylePreset(id: sqlite3_column_int64($0, 0),
                        name: String(cString: sqlite3_column_text($0, 1)),
                        prompt: String(cString: sqlite3_column_text($0, 2)))
        }
    }
    func addStyle(name: String, prompt: String) { run("INSERT INTO styles(name,prompt) VALUES(?,?)", [name, prompt]) }
    func deleteStyle(_ id: Int64) { run("DELETE FROM styles WHERE id=?", [id]) }

    func transforms() -> [Transform] {
        rows("SELECT id,slot,name,prompt FROM transforms ORDER BY slot") {
            Transform(id: sqlite3_column_int64($0, 0), slot: Int(sqlite3_column_int64($0, 1)),
                      name: String(cString: sqlite3_column_text($0, 2)),
                      prompt: String(cString: sqlite3_column_text($0, 3)))
        }
    }
    func addTransform(slot: Int, name: String, prompt: String) { run("INSERT INTO transforms(slot,name,prompt) VALUES(?,?,?)", [slot, name, prompt]) }
    func deleteTransform(_ id: Int64) { run("DELETE FROM transforms WHERE id=?", [id]) }

    func notes() -> [Note] {
        rows("SELECT id,title,body,updated FROM notes ORDER BY updated DESC") {
            Note(id: sqlite3_column_int64($0, 0),
                 title: String(cString: sqlite3_column_text($0, 1)),
                 body: String(cString: sqlite3_column_text($0, 2)),
                 updated: Date(timeIntervalSince1970: sqlite3_column_double($0, 3)))
        }
    }
    func addNote(title: String, body: String) { run("INSERT INTO notes(title,body,updated) VALUES(?,?,?)", [title, body, Date().timeIntervalSince1970]) }
    func updateNote(_ id: Int64, title: String, body: String) { run("UPDATE notes SET title=?,body=?,updated=? WHERE id=?", [title, body, Date().timeIntervalSince1970, id]) }
    func deleteNote(_ id: Int64) { run("DELETE FROM notes WHERE id=?", [id]) }
}
