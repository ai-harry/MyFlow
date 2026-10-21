import SwiftUI
import AppKit

/// History state shared by the list (content column) and detail column of the
/// main window's three-column NavigationSplitView.
@MainActor
final class HistoryModel: ObservableObject {
    @Published var items: [Dictation] = []
    @Published var search = ""
    @Published var selection: Int64?
    @Published var confirmDelete = false

    var selected: Dictation? { items.first { $0.id == selection } }

    var grouped: [(DateBucket, [Dictation])] {
        let now = Date()
        let dict = Dictionary(grouping: items) { DateBucket.bucket(for: $0.ts, now: now) }
        return DateBucket.allCases.compactMap { b in dict[b].map { (b, $0) } }
    }

    var isProcessing: Bool {
        if case .processing = Engine.shared.phase { return true }
        return false
    }

    func displayText(_ d: Dictation) -> String {
        d.status == "ok" ? d.clean : (d.clean.isEmpty ? d.raw : d.clean)
    }
    func hasAudio(_ d: Dictation) -> Bool {
        !d.audioPath.isEmpty && FileManager.default.fileExists(atPath: d.audioPath)
    }

    func copy(_ d: Dictation) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(displayText(d), forType: .string)
    }

    func repaste(_ d: Dictation) {
        let text = displayText(d)
        NSApp.hide(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { Paste.insert(text) }
    }

    func deleteSelected() {
        guard let d = selected else { return }
        let idx = items.firstIndex { $0.id == d.id } ?? 0
        guard Store.shared.deleteDictation(id: d.id) else { return }
        if !d.audioPath.isEmpty {
            let file = URL(fileURLWithPath: d.audioPath).standardizedFileURL.resolvingSymlinksInPath()
            let root = AppSettings.supportDir.appendingPathComponent("pending")
                .standardizedFileURL.resolvingSymlinksInPath()
            let fc = file.pathComponents, rc = root.pathComponents
            if fc.count > rc.count, Array(fc.prefix(rc.count)) == rc, file.pathExtension.lowercased() == "wav" {
                try? FileManager.default.removeItem(at: file)
            }
        }
        items.removeAll { $0.id == d.id }
        selection = items.isEmpty ? nil : items[min(idx, items.count - 1)].id
        Engine.shared.historyVersion += 1
    }

    func reload() {
        items = Store.shared.recentDictations(search: search.trimmingCharacters(in: .whitespacesAndNewlines))
        if let s = selection, !items.contains(where: { $0.id == s }) { selection = nil }
    }
}

/// Content column: grouped dictation list, search, toolbar actions.
struct HistoryListPane: View {
    @ObservedObject var model: HistoryModel
    @ObservedObject var engine = Engine.shared

    var body: some View {
        list
            .navigationTitle("History")
            .searchable(text: $model.search, placement: .toolbar, prompt: "Search dictations")
            .toolbar { toolbarItems }
            .confirmationDialog("Delete this dictation?", isPresented: $model.confirmDelete,
                                titleVisibility: .visible) {
                Button("Delete", role: .destructive) { model.deleteSelected() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This also removes its saved audio. This can't be undone.")
            }
            .onAppear { model.reload() }
            .onChange(of: model.search) { model.reload() }
            .onChange(of: engine.historyVersion) { model.reload() }
    }

    @ViewBuilder private var list: some View {
        if model.items.isEmpty {
            if model.search.isEmpty {
                ContentUnavailableView("No Dictations Yet", systemImage: "waveform",
                                       description: Text("Hold Fn to dictate. Your dictations will show up here."))
            } else {
                ContentUnavailableView.search(text: model.search)
            }
        } else {
            List(selection: $model.selection) {
                ForEach(model.grouped, id: \.0) { bucket, rows in
                    Section(bucket.title) {
                        ForEach(rows) { d in
                            HistoryRow(d: d).tag(d.id)
                        }
                    }
                }
            }
            .listStyle(.inset)
            .onDeleteCommand { if model.selected != nil { model.confirmDelete = true } }
            .onCopyCommand {
                guard let d = model.selected else { return [] }
                return [NSItemProvider(object: model.displayText(d) as NSString)]
            }
        }
    }

    @ToolbarContentBuilder private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup {
            let sel = model.selected
            let noText = sel == nil || sel.map(model.displayText)?.isEmpty == true
            Button { if let d = sel { model.copy(d) } } label: { Label("Copy", systemImage: "doc.on.doc") }
                .help("Copy text")
                .disabled(noText)
            Button { if let d = sel { model.repaste(d) } } label: { Label("Re-paste", systemImage: "arrow.down.doc") }
                .help("Paste into the app you were using")
                .disabled(noText)
            Button { if let d = sel { engine.retryDictation(d) } } label: {
                Label("Retry", systemImage: "arrow.clockwise")
            }
            .help("Transcribe the saved audio again")
            .disabled(!(sel.map(model.hasAudio) ?? false) || model.isProcessing)
            Button { model.confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
                .help("Delete dictation")
                .disabled(sel == nil)
        }
    }
}

/// Detail column: the selected dictation, or a placeholder.
struct HistoryDetailPane: View {
    @ObservedObject var model: HistoryModel
    @ObservedObject var engine = Engine.shared

    var body: some View {
        if let d = model.selected {
            HistoryDetailView(d: d, isProcessing: model.isProcessing, onRetry: { engine.retryDictation(d) })
                .id(d.id)
        } else {
            ContentUnavailableView("Select a Dictation", systemImage: "text.bubble",
                                   description: Text("Choose a dictation from the list to see its details."))
        }
    }
}

// MARK: - Row

struct HistoryRow: View {
    var d: Dictation

    private var failed: Bool { d.status == "failed" || d.status == "cancelled" }

    var body: some View {
        HStack(alignment: .top, spacing: DS.spacing + 4) {
            AppIconView(name: d.appName)
            VStack(alignment: .leading, spacing: 2) {
                if failed {
                    Label(d.status == "cancelled" ? "Recording cancelled" : "Couldn't transcribe",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.body).foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text(d.clean).font(.body).lineLimit(2)
                }
                HStack(spacing: 4) {
                    Text(d.appName).lineLimit(1)
                    if d.mode == "loud" { Image(systemName: "speaker.wave.3.fill").help("Loud mode") }
                    if d.mode == "ai" { Image(systemName: "sparkles").help("AI mode") }
                }
                .font(.caption).foregroundStyle(.tertiary)
            }
            Spacer(minLength: DS.spacing)
            Text(d.ts, style: .time)
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
