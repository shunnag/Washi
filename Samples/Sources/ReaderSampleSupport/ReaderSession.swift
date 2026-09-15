import AppKit
import Combine
import Washi
import UniformTypeIdentifiers

// 開いている出版物と進行中の解析が、それぞれ必要な間だけアクセス権を保持する。
// 終了した要求のローカル変数もこのオブジェクトを保持するので、解析途中で失効しない。
private final class FileAccess: Sendable {
    let url: URL
    let started: Bool

    init(_ url: URL) {
        self.url = url
        started = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if started { url.stopAccessingSecurityScopedResource() }
    }
}

/// サンプルで共用する、ウインドウごとの読書状態。Washi の公開 API のみを使う。
/// Per-window sample reading state, using only Washi's public API.
@MainActor
public final class ReaderSession: ObservableObject, EPUBReaderViewDelegate {
    public enum Phase: Equatable { case idle, opening, displaying, ready, failed }

    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var title = "Washi"
    @Published public private(set) var position = "本を選んでください / Choose a book"
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var hits: [EPUBSearchHit] = []
    @Published public private(set) var isSearching = false
    @Published public private(set) var totalPages: Int?
    public let reader = EPUBReaderView(frame: .zero)

    private let defaults: UserDefaults
    private let opener: @Sendable (URL) async throws -> EPUBPublication
    private var openTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var navigationTask: Task<Void, Never>?
    private var generation = UUID()
    private var searchGeneration = UUID()
    private var access: FileAccess?
    private var currentURL: URL?

    public convenience init() {
        self.init(defaults: .standard, opener: { try await EPUBPublication.open(url: $0) })
    }

    // 検証では解析の完了順を制御し、古い要求が新しい本を上書きしないことを確かめる。
    init(defaults: UserDefaults, opener: @escaping @Sendable (URL) async throws -> EPUBPublication) {
        self.defaults = defaults
        self.opener = opener
        reader.delegate = self
    }

    public static var demoURL: URL {
        Bundle.main.url(forResource: "Demo", withExtension: "epub")
            ?? Bundle.module.url(forResource: "Demo", withExtension: "epub")!
    }

    public var status: String {
        switch phase {
        case .idle: return position
        case .opening: return "解析中 / Opening…"
        case .displaying: return "本文を表示中 / Preparing page…"
        case .failed: return errorMessage ?? "読み込み失敗 / Load failed"
        case .ready:
            let total = totalPages.map { "全 \($0) ページ / total" }
                ?? "総ページ数は未確定 / Total pending"
            return "\(position) · \(total)"
        }
    }

    public func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "epub") ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    public func open(_ url: URL) {
        close()
        let request = generation
        let fileAccess = FileAccess(url)
        phase = .opening
        openTask = Task { [weak self, opener] in
            guard !Task.isCancelled else { return }
            do {
                let publication = try await opener(url)
                guard !Task.isCancelled, let self, self.generation == request else { return }
                self.access = fileAccess
                self.currentURL = url
                self.title = publication.metadata.mainTitle ?? url.lastPathComponent
                let locator = self.savedLocator(for: url)
                self.phase = .displaying
                self.reader.load(publication: publication, at: locator)
                self.openTask = nil
            } catch {
                guard !Task.isCancelled, let self, self.generation == request else { return }
                self.errorMessage = error.localizedDescription
                self.phase = .failed
                self.openTask = nil
            }
            // キャンセルで早期 return した場合も、非同期解析の完了までは保持される。
            withExtendedLifetime(fileAccess) {}
        }
    }

    public func close() {
        generation = UUID()
        searchGeneration = UUID()
        openTask?.cancel()
        openTask = nil
        searchTask?.cancel()
        searchTask = nil
        navigationTask?.cancel()
        navigationTask = nil
        phase = .idle
        currentURL = nil
        reader.unload()
        access = nil
        title = "Washi"
        hits = []
        isSearching = false
        totalPages = nil
        errorMessage = nil
        position = "本を選んでください / Choose a book"
    }

    public func search(_ query: String) {
        searchTask?.cancel()
        searchTask = nil
        navigationTask?.cancel()
        navigationTask = nil
        let request = UUID()
        searchGeneration = request
        hits = []
        reader.highlights = []
        guard let publication = reader.publication, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            isSearching = false
            return
        }
        isSearching = true
        // Task {} だけでは main actor を引き継ぐ。同期検索は明示的に外へ出す。
        let searchAccess = access
        let worker = Task.detached(priority: .userInitiated) {
            defer { withExtendedLifetime(searchAccess) {} }
            return publication.search(query)
        }
        searchTask = Task { [weak self] in
            let results = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled, let self, self.searchGeneration == request else { return }
            self.hits = results
            self.isSearching = false
            self.searchTask = nil
        }
    }

    public func showHit(at index: Int) {
        guard hits.indices.contains(index), let publication = reader.publication else { return }
        navigationTask?.cancel()
        let hit = hits[index]
        let locator = publication.locator(forSpineIndex: hit.spineIndex)
        let range = (utf16Offset: hit.utf16Range.lowerBound, utf16Length: hit.utf16Range.count)
        // 保存済みの注釈と併用するアプリでは、検索用と永続用の配列を合成して渡す。
        reader.highlights = [EPUBHighlight(
            id: "search", spineIndex: hit.spineIndex, idref: locator.idref,
            utf16Offset: range.utf16Offset, utf16Length: range.utf16Length)]
        let request = generation
        navigationTask = Task { [weak self] in
            guard !Task.isCancelled, let self else { return }
            let landing = await self.reader.go(to: locator, textRange: range)
            guard !Task.isCancelled, self.generation == request else { return }
            // nil は範囲不一致や FXL でも返る。章への移動で読書を継続できるようにする。
            if landing == nil { self.reader.go(to: locator) }
        }
    }

    public func readerView(_ view: EPUBReaderView, didMoveTo locator: EPUBLocator,
                           pageInItem: Int, pageCountInItem: Int) {
        guard let currentURL, phase != .idle else { return }
        phase = .ready
        errorMessage = nil
        position = "章 \(locator.spineIndex + 1) · \(pageInItem + 1)/\(pageCountInItem)"
        if let data = try? JSONEncoder().encode(locator) {
            defaults.set(data, forKey: positionKey(currentURL))
        }
    }

    public func readerViewDidUpdatePageCensus(_ view: EPUBReaderView) {
        totalPages = view.censusTotalPages
    }

    public func readerView(_ view: EPUBReaderView, didFailWith error: any Error) {
        guard phase != .idle else { return }
        errorMessage = error.localizedDescription
        phase = .failed
    }

    private func positionKey(_ url: URL) -> String { "WashiSample.locator." + url.absoluteString }

    private func savedLocator(for url: URL) -> EPUBLocator? {
        defaults.data(forKey: positionKey(url)).flatMap { try? JSONDecoder().decode(EPUBLocator.self, from: $0) }
    }
}
