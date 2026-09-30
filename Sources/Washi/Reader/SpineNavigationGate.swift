import WebKit

enum SpineNavigationDisposition: Equatable {
    case allowExpectedLoad
    case cancelAbandonedLoad
    case routeThroughReader
}

/// 自分で発行した spine ロードだけを一度 allow し、文書が発行した遷移は
/// reader の状態更新経路へ戻すための期待値管理
struct SpineNavigationGate {
    // WebKit は stopLoading() で止めた読み込みも含めて発行順に policy 判定を届ける。
    // 同じパスの古い取消待ちと新しい期待値も、その順序を保って照合する。
    private var entries: [(path: String, generation: Int, isAbandoned: Bool)] = []
    private var terminatedProcessGeneration: Int?

    mutating func expect(_ path: String, generation: Int) {
        entries.append((path, generation, false))
    }

    mutating func cancelExpectation(for path: String) {
        guard let index = entries.lastIndex(where: { $0.path == path && !$0.isAbandoned })
        else { return }
        entries.remove(at: index)
    }

    /// 打ち切った読み込みの遅い policy 判定を文書発行の移動と扱うと、失敗した
    /// 項目を再び読み込み、復旧を上書きしてしまう。未配達の期待値は取消用に残す。
    mutating func abandonPendingExpectations() {
        for index in entries.indices { entries[index].isAbandoned = true }
    }

    /// setup を終えた世代以前に policy 待ちは残らない。取消の有無を問わず除去し、
    /// 通知からの再入で始まった後の世代の期待値は残す。
    mutating func dropExpectations(through generation: Int) {
        entries.removeAll { $0.generation <= generation }
    }

    /// 終了直前の policy 判定が UI プロセスに届き、MainActor の実行待ちの場合が
    /// あるため、ここでは除去せず取り消せる形で残す。
    mutating func abandonForProcessTermination() {
        abandonPendingExpectations()
        terminatedProcessGeneration = entries.map { $0.generation }.max()
    }

    /// 次の読み込みでは、終了したプロセスからもう届かない期待値を除去する。
    /// 同じパスの新しい読み込みを古い取消待ちに対応させない。
    mutating func dropTerminatedProcessExpectations() {
        guard let generation = terminatedProcessGeneration else { return }
        dropExpectations(through: generation)
        terminatedProcessGeneration = nil
    }

    mutating func disposition(for path: String,
                              navigationType: WKNavigationType)
        -> SpineNavigationDisposition {
        guard navigationType == .other else {
            return .routeThroughReader
        }
        guard let index = entries.firstIndex(where: { $0.path == path })
        else { return .routeThroughReader }
        let entry = entries.remove(at: index)
        return entry.isAbandoned ? .cancelAbandonedLoad : .allowExpectedLoad
    }
}
