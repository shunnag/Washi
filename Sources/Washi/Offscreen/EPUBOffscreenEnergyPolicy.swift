import Foundation

/// オフスクリーン WebKit 処理(ページ数の実測 census・画面サムネイル・その中で
/// 委譲する固定レイアウト描画)の省エネ方針。
///
/// Energy policy for offscreen WebKit work (the pagination census, screen
/// thumbnails and the fixed-layout rendering they delegate to).
///
/// 既定の ``unrestricted`` は従来どおり制限なしで、``followSystem`` を選ぶと
/// 低電力モードや熱状態の上昇に応じて処理の間に短い休止を入れる。方針で変わるのは
/// 処理を**いつ**行うかだけで、ページ数や画像は変わらない。
/// ``EPUBReaderView/offscreenEnergyPolicy`` と
/// ``EPUBScreenAtlas/offscreenEnergyPolicy`` で設定する。
///
/// The default ``unrestricted`` behaves exactly as before; ``followSystem``
/// inserts short pauses between work items while Low Power Mode is on or the
/// thermal state is elevated. The policy only changes *when* the work runs,
/// never the page counts or images it produces. Set it through
/// ``EPUBReaderView/offscreenEnergyPolicy`` and
/// ``EPUBScreenAtlas/offscreenEnergyPolicy``.
public struct EPUBOffscreenEnergyPolicy: Sendable, Hashable {
    // 公開 enum にすると利用側の exhaustive switch が将来の追加で壊れるため、
    // 内部 enum を包む struct にして定数で選ばせる。
    enum Mode: Sendable, Hashable {
        case unrestricted
        case followSystem
    }

    let mode: Mode

    /// 既定。システムの状態を読まず、処理を連続して行う(従来どおり)。
    ///
    /// The default. Never consults the system state and runs the work
    /// back-to-back, exactly as before.
    public static let unrestricted = EPUBOffscreenEnergyPolicy(mode: .unrestricted)

    /// 低電力モードが有効か、熱状態が `.serious` / `.critical` のとき、census で
    /// WebKit に読み込む spine 項目とサムネイルのジョブの前に 50 ms の休止を入れる。
    /// 熱状態が `.critical` の間は、まだ始めていない census を始めずに回復を待つ。
    /// 処理の優先度は下げない。実行中に方針を変えると次の項目/ジョブから反映される。
    ///
    /// Pauses 50 ms before each census spine item loaded in WebKit and each
    /// thumbnail job while Low Power Mode is enabled or the thermal state is
    /// `.serious` / `.critical`, and holds a census that has not started yet
    /// while the thermal state is `.critical`. The task priority is never
    /// lowered. Changing the policy at run time applies from the next item or
    /// job.
    public static let followSystem = EPUBOffscreenEnergyPolicy(mode: .followSystem)
}

extension EPUBOffscreenEnergyPolicy {
    /// 省エネ時に項目/ジョブの前へ入れる休止。census の 1 項目は読み込みと setup で
    /// 概ね 100〜300 ms なので、50 ms なら総時間は 2〜3 割伸びる程度で CPU の
    /// 稼働率は目に見えて下がる(秒単位にすると大きい本の census が終わらなくなる)。
    static let conservingPause: Duration = .milliseconds(50)

    /// `.critical` の間、census を始めてよいかを確認し直す間隔。
    static let deferralPollInterval: Duration = .seconds(1)

    /// システムの状態を読む必要があるか(unrestricted は ProcessInfo に触れない)。
    var consultsSystemState: Bool { mode == .followSystem }

    /// この状態で項目/ジョブの前に入れる休止。nil なら休止なし。
    func pauseBeforeJob(in state: EPUBOffscreenSystemEnergyState) -> Duration? {
        guard consultsSystemState, Self.asksToConserve(state) else { return nil }
        return Self.conservingPause
    }

    /// この状態では、まだ始めていない処理の開始を延期するか。
    func defersStart(in state: EPUBOffscreenSystemEnergyState) -> Bool {
        consultsSystemState && state.thermalState == .critical
    }

    static func asksToConserve(_ state: EPUBOffscreenSystemEnergyState) -> Bool {
        state.isLowPowerModeEnabled
            || state.thermalState == .serious || state.thermalState == .critical
    }
}

/// 省エネ判断の入力。本番は ProcessInfo から読み、テストではホスト機の状態に
/// 依存しないよう差し替える。
struct EPUBOffscreenSystemEnergyState: Sendable, Equatable {
    var isLowPowerModeEnabled = false
    var thermalState: ProcessInfo.ThermalState = .nominal

    static func current() -> EPUBOffscreenSystemEnergyState {
        let info = ProcessInfo.processInfo
        return EPUBOffscreenSystemEnergyState(
            isLowPowerModeEnabled: info.isLowPowerModeEnabled,
            thermalState: info.thermalState)
    }
}

/// 方針と実機の状態から、オフスクリーン処理の間の休止と開始の延期を実行する。
/// 所有者(EPUBReaderView / EPUBScreenAtlas)が 1 つ持ち、その census と
/// サムネイルレンダラへ渡すので、公開プロパティの変更は直ちに両方へ届く。
/// 休止は呼び出し元のタスク(`.userInitiated`)の中で待つだけで優先度は変えない —
/// 低い QoS で WebKit の JS を呼ぶと最初の応答が返らない(Pagination.md)。
@MainActor
final class EPUBOffscreenEnergyPacer {
    typealias StateProvider = @MainActor @Sendable () -> EPUBOffscreenSystemEnergyState
    typealias Sleep = @MainActor @Sendable (Duration) async throws -> Void

    /// 所有者の公開プロパティの実体。毎回読み直すので実行中の変更も効く。
    var policy: EPUBOffscreenEnergyPolicy = .unrestricted
    private let state: StateProvider
    private let sleep: Sleep

    init(
        state: @escaping StateProvider = { EPUBOffscreenSystemEnergyState.current() },
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) {
        self.state = state
        self.sleep = sleep
    }

    /// unrestricted は状態を読まない。並列 census の追加ホストも同じ省エネ判断に従う。
    var isConserving: Bool {
        policy.consultsSystemState && EPUBOffscreenEnergyPolicy.asksToConserve(state())
    }

    /// WebKit を使う項目/ジョブの直前に呼ぶ。省エネが求められていなければ
    /// 何も待たず、unrestricted ならシステムの状態も読まない。キャンセルは投げる。
    func pauseBeforeJobIfNeeded() async throws {
        guard policy.consultsSystemState,
              let pause = policy.pauseBeforeJob(in: state()) else { return }
        try await sleep(pause)
    }

    /// まだ始めていない処理を始めてよくなるまで待つ(`.critical` の間だけ)。
    /// 方針は毎回読み直すので、unrestricted に戻せば直ちに抜ける。`isAborted` は
    /// 状態を読む前に毎回確かめ、呼び出し元の中断(invalidate)を待たせない。
    /// キャンセルは投げる。
    func waitUntilStartAllowed(isAborted: () -> Bool) async throws {
        while policy.consultsSystemState {
            // 差し替えた sleep がキャンセルを見ないことがあるので、ここでも確認する。
            try Task.checkCancellation()
            guard !isAborted(), policy.defersStart(in: state()) else { return }
            try await sleep(EPUBOffscreenEnergyPolicy.deferralPollInterval)
        }
    }
}
