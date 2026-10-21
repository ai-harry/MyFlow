import SwiftUI

// MARK: - Dictionary

struct DictionaryView: View {
    @State private var words: [VocabWord] = []
    @State private var newWord = ""
    @State private var adding = false

    var body: some View {
        Group {
            if words.isEmpty {
                ContentUnavailableView("No Words Yet", systemImage: "character.book.closed",
                    description: Text("Add names, jargon and technical terms. They bias transcription and cleanup."))
            } else {
                List {
                    Section {
                        ForEach(words) { w in
                            Text(w.word)
                                .contextMenu { Button("Delete", role: .destructive) { delete(w) } }
                                .swipeActions { Button("Delete", role: .destructive) { delete(w) } }
                        }
                    } header: {
                        Text("Names, jargon and technical terms help Flow spell the way you do.")
                    }
                }
            }
        }
        .navigationTitle("Dictionary")
        .toolbar {
            ToolbarItem { Button { adding = true } label: { Label("Add Word", systemImage: "plus") } }
        }
        .sheet(isPresented: $adding) {
            AddSheet(title: "New Word", canSave: !newWord.trimmingCharacters(in: .whitespaces).isEmpty,
                     onSave: add) {
                TextField("Word or name", text: $newWord)
            }
        }
        .onAppear(perform: reload)
    }

    private func add() {
        let w = newWord.trimmingCharacters(in: .whitespaces)
        guard !w.isEmpty else { return }
        Store.shared.addVocab(w); newWord = ""; reload()
    }
    private func delete(_ w: VocabWord) { Store.shared.deleteVocab(w.id); reload() }
    private func reload() { words = Store.shared.vocab() }
}

// MARK: - Snippets

struct SnippetsView: View {
    @State private var snippets: [Snippet] = []
    @State private var trigger = ""
    @State private var expansion = ""
    @State private var adding = false

    var body: some View {
        Group {
            if snippets.isEmpty {
                ContentUnavailableView("No Snippets Yet", systemImage: "text.insert",
                    description: Text("Say a trigger while dictating and Flow drops in the expansion."))
            } else {
                List {
                    Section {
                        ForEach(snippets) { s in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.trigger).font(.headline)
                                Text(s.expansion).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                            }
                            .padding(.vertical, 2)
                            .contextMenu { Button("Delete", role: .destructive) { delete(s) } }
                            .swipeActions { Button("Delete", role: .destructive) { delete(s) } }
                        }
                    } header: {
                        Text("Say the trigger while dictating and Flow inserts the expansion.")
                    }
                }
            }
        }
        .navigationTitle("Snippets")
        .toolbar {
            ToolbarItem { Button { adding = true } label: { Label("Add Snippet", systemImage: "plus") } }
        }
        .sheet(isPresented: $adding) {
            AddSheet(title: "New Snippet", canSave: !trigger.isEmpty && !expansion.isEmpty, onSave: {
                Store.shared.addSnippet(trigger: trigger, expansion: expansion)
                trigger = ""; expansion = ""; reload()
            }) {
                TextField("Trigger", text: $trigger, prompt: Text("my email"))
                TextField("Expansion", text: $expansion, prompt: Text("name@example.com"), axis: .vertical)
                    .lineLimit(2...6)
            }
        }
        .onAppear(perform: reload)
    }
    private func delete(_ s: Snippet) { Store.shared.deleteSnippet(s.id); reload() }
    private func reload() { snippets = Store.shared.snippets() }
}

// MARK: - Style

struct StyleView: View {
    @ObservedObject var settings = AppSettings.shared
    @State private var styles: [StylePreset] = []
    @State private var name = ""
    @State private var prompt = ""
    @State private var adding = false

    var body: some View {
        Group {
            if styles.isEmpty {
                ContentUnavailableView("No Styles", systemImage: "textformat",
                    description: Text("A style shapes how cleanup writes your dictation."))
            } else {
                List {
                    Section {
                        ForEach(styles) { s in
                            HStack(spacing: DS.spacingL) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(s.name).font(.headline)
                                    Text(s.prompt).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                                }
                                Spacer()
                                if settings.activeStyleID == Int(s.id) {
                                    Label("Active", systemImage: "checkmark.circle.fill")
                                        .foregroundStyle(.tint).font(.callout)
                                } else {
                                    Button("Use") { settings.activeStyleID = Int(s.id) }
                                }
                            }
                            .padding(.vertical, 2)
                            .contextMenu {
                                Button("Use This Style") { settings.activeStyleID = Int(s.id) }
                                Button("Delete", role: .destructive) { delete(s) }
                            }
                            .swipeActions { Button("Delete", role: .destructive) { delete(s) } }
                        }
                    } header: {
                        Text("The active style shapes every dictation.")
                    }
                }
            }
        }
        .navigationTitle("Style")
        .toolbar {
            ToolbarItem { Button { adding = true } label: { Label("Add Style", systemImage: "plus") } }
        }
        .sheet(isPresented: $adding) {
            AddSheet(title: "New Style", canSave: !name.isEmpty && !prompt.isEmpty, onSave: {
                Store.shared.addStyle(name: name, prompt: prompt)
                name = ""; prompt = ""; reload()
            }) {
                TextField("Name", text: $name)
                TextField("Instructions", text: $prompt, axis: .vertical).lineLimit(3...8)
            }
        }
        .onAppear(perform: reload)
    }
    private func delete(_ s: StylePreset) { Store.shared.deleteStyle(s.id); reload() }
    private func reload() { styles = Store.shared.styles() }
}

// MARK: - Transforms

struct TransformsView: View {
    @ObservedObject var settings = AppSettings.shared
    @State private var transforms: [Transform] = []
    @State private var name = ""
    @State private var prompt = ""
    @State private var slot = 3
    @State private var adding = false

    var body: some View {
        List {
            Section {
                Toggle("Enable ⌥-number hotkeys", isOn: $settings.transformHotkeysEnabled)
            } footer: {
                Text("Select text anywhere, press ⌥ and a number, and the transform rewrites it in place.")
            }
            Section("Transforms") {
                if transforms.isEmpty {
                    ContentUnavailableView("No Transforms Yet", systemImage: "wand.and.stars",
                        description: Text("Add a transform to rewrite selected text with a hotkey."))
                }
                ForEach(transforms) { t in
                    HStack(alignment: .top, spacing: DS.spacingL) {
                        Text("⌥ \(t.slot)")
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.name).font(.headline)
                            Text(t.prompt).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                        }
                    }
                    .padding(.vertical, 2)
                    .contextMenu { Button("Delete", role: .destructive) { delete(t) } }
                    .swipeActions { Button("Delete", role: .destructive) { delete(t) } }
                }
            }
        }
        .navigationTitle("Transforms")
        .toolbar {
            ToolbarItem { Button { adding = true } label: { Label("Add Transform", systemImage: "plus") } }
        }
        .sheet(isPresented: $adding) {
            AddSheet(title: "New Transform", canSave: !name.isEmpty && !prompt.isEmpty, onSave: {
                Store.shared.addTransform(slot: slot, name: name, prompt: prompt)
                name = ""; prompt = ""; reload()
            }) {
                TextField("Name", text: $name)
                TextField("Instruction", text: $prompt, axis: .vertical).lineLimit(2...6)
                Picker("Hotkey", selection: $slot) {
                    ForEach(1...9, id: \.self) { Text("⌥ \($0)").tag($0) }
                }
            }
        }
        .onAppear(perform: reload)
    }
    private func delete(_ t: Transform) { Store.shared.deleteTransform(t.id); reload() }
    private func reload() { transforms = Store.shared.transforms() }
}

// MARK: - Scratchpad

struct ScratchpadView: View {
    @State private var notes: [Note] = []
    @State private var selectedID: Int64?
    @State private var draftTitle = ""
    @State private var draftBody = ""
    @State private var confirmDelete = false

    var body: some View {
        HSplitView {
            Group {
                if notes.isEmpty {
                    ContentUnavailableView("No Notes", systemImage: "note.text",
                        description: Text("Quick thoughts you want to come back to."))
                } else {
                    List(selection: Binding(get: { selectedID }, set: { select($0) })) {
                        ForEach(notes) { n in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(n.title.isEmpty ? "Untitled" : n.title).font(.headline).lineLimit(1)
                                Text(n.body.isEmpty ? "No additional text" : n.body)
                                    .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                                Text(n.updated, style: .date).font(.caption).foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 2)
                            .tag(n.id)
                        }
                    }
                    .listStyle(.inset)
                }
            }
            .frame(minWidth: 220, idealWidth: 260, maxWidth: 360)

            Group {
                if selectedID != nil {
                    VStack(spacing: 0) {
                        TextField("Title", text: $draftTitle)
                            .font(.title2.bold())
                            .textFieldStyle(.plain)
                            .padding([.horizontal, .top], DS.spacingL)
                        TextEditor(text: $draftBody)
                            .font(.body)
                            .scrollContentBackground(.hidden)
                            .padding(DS.spacing)
                    }
                    .onChange(of: draftTitle) { save() }
                    .onChange(of: draftBody) { save() }
                } else {
                    ContentUnavailableView("Select a Note", systemImage: "note.text")
                }
            }
            .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Scratchpad")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    Store.shared.addNote(title: "Untitled", body: "")
                    reload(); select(notes.first?.id)
                } label: { Label("New Note", systemImage: "square.and.pencil") }
                Button { confirmDelete = true } label: { Label("Delete Note", systemImage: "trash") }
                    .disabled(selectedID == nil)
            }
        }
        .confirmationDialog("Delete this note?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let id = selectedID { Store.shared.deleteNote(id) }
                selectedID = nil; draftTitle = ""; draftBody = ""; reload()
            }
            Button("Cancel", role: .cancel) {}
        }
        .onAppear { reload() }
        .onDisappear { save(); }
    }

    private func reload() { notes = Store.shared.notes() }

    private func select(_ id: Int64?) {
        save(); reload()
        selectedID = id
        let n = notes.first { $0.id == id }
        loading = true
        draftTitle = n?.title ?? ""; draftBody = n?.body ?? ""
        DispatchQueue.main.async { loading = false }
    }

    @State private var loading = false
    private func save() {
        guard !loading, let id = selectedID else { return }
        Store.shared.updateNote(id, title: draftTitle, body: draftBody)
    }
}
