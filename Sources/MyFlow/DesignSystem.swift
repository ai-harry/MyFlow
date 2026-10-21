import SwiftUI
import AppKit

/// Shared layout constants for the main window (8pt grid).
enum DS {
    static let spacing: CGFloat = 8
    static let spacingL: CGFloat = 16
    static let spacingXL: CGFloat = 24
    static let radius: CGFloat = 10
    static let iconSize: CGFloat = 28
}

/// Resolves a source-app NAME to its icon by searching the standard
/// application folders. Results (including misses) are cached in memory.
@MainActor
enum AppIconCache {
    private static var cache: [String: NSImage?] = [:]
    private static let dirs = ["/Applications", "/System/Applications",
                               "/System/Applications/Utilities", "/Applications/Utilities",
                               NSHomeDirectory() + "/Applications"]

    static func icon(for name: String) -> NSImage? {
        if let hit = cache[name] { return hit }
        var found: NSImage?
        if let running = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name }),
           let i = running.icon {
            found = i
        } else {
            for d in dirs {
                let path = "\(d)/\(name).app"
                if FileManager.default.fileExists(atPath: path) {
                    found = NSWorkspace.shared.icon(forFile: path); break
                }
            }
        }
        cache[name] = .some(found)
        return found
    }
}

struct AppIconView: View {
    var name: String
    var size: CGFloat = DS.iconSize
    var body: some View {
        if let img = AppIconCache.icon(for: name) {
            Image(nsImage: img).resizable().interpolation(.high)
                .frame(width: size, height: size)
        } else {
            Image(systemName: "app")
                .font(.system(size: size * 0.7))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
        }
    }
}

/// Relative date buckets for the history list.
enum DateBucket: Int, CaseIterable, Identifiable {
    case today, yesterday, thisWeek, earlier
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .thisWeek: return "This Week"
        case .earlier: return "Earlier"
        }
    }
    static func bucket(for date: Date, now: Date = Date()) -> DateBucket {
        let cal = Calendar.current
        if cal.isDate(date, inSameDayAs: now) { return .today }
        if cal.isDateInYesterday(date) { return .yesterday }
        if let week = cal.dateInterval(of: .weekOfYear, for: now), week.contains(date) { return .thisWeek }
        return .earlier
    }
}

func wordCount(_ s: String) -> Int {
    s.split(whereSeparator: { $0.isWhitespace }).count
}

func formatDuration(_ t: TimeInterval) -> String {
    let s = Int(max(0, t).rounded())
    return String(format: "%d:%02d", s / 60, s % 60)
}

/// Standard "add item" sheet: grouped Form + Cancel/Add buttons.
struct AddSheet<Content: View>: View {
    var title: String
    var canSave: Bool
    var onSave: () -> Void
    @ViewBuilder var content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Text(title).font(.headline).padding(.top, DS.spacingL)
            Form { content }.formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") { onSave(); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding(DS.spacingL)
        }
        .frame(width: 440)
    }
}
