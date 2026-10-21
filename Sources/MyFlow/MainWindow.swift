import SwiftUI

enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case history = "History"
    case scratchpad = "Scratchpad"
    case dictionary = "Dictionary"
    case snippets = "Snippets"
    case style = "Style"
    case transforms = "Transforms"
    case insights = "Insights"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .history: return "clock"
        case .scratchpad: return "note.text"
        case .dictionary: return "character.book.closed"
        case .snippets: return "text.insert"
        case .style: return "textformat"
        case .transforms: return "wand.and.stars"
        case .insights: return "chart.bar"
        }
    }
}

struct MainWindowView: View {
    @State private var section: AppSection? = .history
    @StateObject private var history = HistoryModel()

    var body: some View {
        Group {
            if (section ?? .history) == .history {
                NavigationSplitView {
                    sidebar
                } content: {
                    HistoryListPane(model: history)
                        .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 480)
                } detail: {
                    HistoryDetailPane(model: history)
                }
            } else {
                NavigationSplitView {
                    sidebar
                } detail: {
                    page
                }
            }
        }
        .frame(minWidth: 820, minHeight: 520)
    }

    private var sidebar: some View {
        List(selection: $section) {
            Section("Library") {
                row(.history); row(.scratchpad)
            }
            Section("Customise") {
                row(.dictionary); row(.snippets); row(.style); row(.transforms)
            }
            Section {
                row(.insights)
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
    }

    @ViewBuilder private var page: some View {
        switch section ?? .history {
        case .history: EmptyView()
        case .scratchpad: ScratchpadView()
        case .dictionary: DictionaryView()
        case .snippets: SnippetsView()
        case .style: StyleView()
        case .transforms: TransformsView()
        case .insights: InsightsView()
        }
    }

    private func row(_ s: AppSection) -> some View {
        Label(s.rawValue, systemImage: s.icon).tag(s)
    }
}
