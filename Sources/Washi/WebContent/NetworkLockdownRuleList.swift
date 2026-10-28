import OSLog
import WebKit

/// 画面上・画面外の初回読み込みに先立って、共通の外部通信ルールを用意する。
@MainActor
final class NetworkLockdownRuleList {
    static let shared = NetworkLockdownRuleList()

    private static let logger = Logger(
        subsystem: "org.cocoadialog.Washi", category: "NetworkLockdownRuleList")

    private let compile: @MainActor () async throws -> WKContentRuleList
    private let didFail: (@MainActor (any Error) -> Void)?
    private let didInstall: (@MainActor (WKUserContentController) -> Void)?
    private var compilation: Task<Void, Never>?
    private var hasCompiled = false
    private var ruleList: WKContentRuleList?

    // コンパイルと観測点をインスタンスごとに差し替え、共有状態を汚さず失敗を検証する。
    init(
        compile: @escaping @MainActor () async throws -> WKContentRuleList = compileRules,
        didFail: (@MainActor (any Error) -> Void)? = nil,
        didInstall: (@MainActor (WKUserContentController) -> Void)? = nil
    ) {
        self.compile = compile
        self.didFail = didFail
        self.didInstall = didInstall
    }

    func prepare() async {
        if hasCompiled { return }
        if let compilation {
            await compilation.value
            return
        }
        // 最初の呼び出し元の優先度に依存させず、画面外ジョブと同じ優先度で準備する。
        let task = Task(priority: .userInitiated) { @MainActor in
            do {
                self.ruleList = try await self.compile()
            } catch {
                // CSP と遷移制限を保って描画を続けるが、保護層の欠落は黙殺しない。
                Self.logger.error("外部通信ルールのコンパイルに失敗: \(error, privacy: .public)")
                self.didFail?(error)
            }
            self.hasCompiled = true
        }
        compilation = task
        await task.value
        compilation = nil
    }

    /// 準備済みなら同期的に登録する。失敗も確定済みとして扱い、以後は待たない。
    @discardableResult
    func installIfReady(in controller: WKUserContentController) -> Bool {
        guard hasCompiled else { return false }
        if let ruleList {
            controller.add(ruleList)
            didInstall?(controller)
        }
        return true
    }

    static func compileRules() async throws -> WKContentRuleList {
        guard let store = WKContentRuleListStore.default() else {
            throw CompilationError.storeUnavailable
        }
        let json = """
        [
          {"trigger": {"url-filter": "https?://.*"}, "action": {"type": "block"}},
          {"trigger": {"url-filter": "wss?://.*"}, "action": {"type": "block"}},
          {"trigger": {"url-filter": "^washi-epub://.*"},
           "action": {"type": "ignore-previous-rules"}}
        ]
        """
        guard let ruleList = try await store.compileContentRuleList(
            forIdentifier: "washi-network-lockdown", encodedContentRuleList: json)
        else { throw CompilationError.missingRuleList }
        return ruleList
    }

    private enum CompilationError: Error {
        case storeUnavailable
        case missingRuleList
    }
}
