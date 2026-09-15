import SwiftUI
import ReaderSampleSupport

@main
struct SwiftUIReaderApp: App {
    var body: some Scene {
        WindowGroup("Washi · SwiftUI") { ReaderWindow() }
            .defaultSize(width: 900, height: 700)
    }
}

private struct ReaderWindow: View {
    @StateObject private var session = ReaderSession()
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("開く / Open…") { session.chooseFile() }
                Button("サンプル / Demo") { session.open(ReaderSession.demoURL) }
                Button("前へ / Previous") { session.reader.goBackward() }
                    .disabled(session.phase != .ready)
                Button("次へ / Next") { session.reader.goForward() }
                    .disabled(session.phase != .ready)
                TextField("検索 / Search", text: $query)
                    .onSubmit { session.search(query) }
                    .disabled(session.phase != .ready)
                    .frame(maxWidth: 180)
                if session.isSearching { ProgressView().controlSize(.small) }
            }
            .padding(10)
            HStack(spacing: 0) {
                if !session.hits.isEmpty {
                    List(session.hits.indices, id: \.self) { index in
                        Button(session.hits[index].snippet) { session.showHit(at: index) }
                            .buttonStyle(.plain)
                    }
                    .frame(width: 220)
                }
                ReaderSurface(session: session)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Text(session.status)
                .foregroundStyle(session.errorMessage == nil ? Color.secondary : Color.red)
                .font(.caption)
                .textSelection(.enabled)
                .padding(8)
        }
        .frame(minWidth: 760, minHeight: 500)
        .navigationTitle(session.title)
        .task { session.open(ReaderSession.demoURL) }
    }
}
