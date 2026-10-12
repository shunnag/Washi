import AppKit
import XCTest
@testable import Washi
@testable import WashiCore

/// ホスト機の状態に依存しない省エネ判断の入力。読まれた回数も数える
/// (unrestricted が ProcessInfo に触れないことの観測点)。
@MainActor
private final class FakeEnergyState {
    var state = EPUBOffscreenSystemEnergyState()
    private(set) var readCount = 0

    var provider: EPUBOffscreenEnergyPacer.StateProvider {
        { [weak self] in
            guard let self else { return EPUBOffscreenSystemEnergyState() }
            readCount += 1
            return state
        }
    }
}

/// 実時間を待たずに休止を記録する。50 ms は項目/ジョブの休止、1 s は開始延期の
/// 再確認なので、記録した長さの列がそのまま種類の列になる。休止を呼んだタスクの
/// 優先度も控える(QoS を下げないことの観測点)。
@MainActor
private final class PauseRecorder {
    private(set) var pauses: [Duration] = []
    private(set) var priorities: [TaskPriority] = []
    /// n 回目(1 始まり)の休止で呼ぶ(状態や方針を実行中に変える操作)。
    var onPause: @MainActor (Int) -> Void = { _ in }
    /// true なら記録したうえでキャンセルとして投げる(待機中のキャンセルの再現)。
    var throwsCancellation = false

    var sleep: EPUBOffscreenEnergyPacer.Sleep {
        { [weak self] duration in
            guard let self else { return }
            pauses.append(duration)
            priorities.append(Task.currentPriority)
            onPause(pauses.count)
            if throwsCancellation { throw CancellationError() }
        }
    }

    func makePacer(state: FakeEnergyState,
                   policy: EPUBOffscreenEnergyPolicy) -> EPUBOffscreenEnergyPacer {
        let pacer = EPUBOffscreenEnergyPacer(state: state.provider, sleep: sleep)
        pacer.policy = policy
        return pacer
    }
}

@MainActor
final class EPUBOffscreenEnergyPolicyTests: XCTestCase {
    private static let lowPower = EPUBOffscreenSystemEnergyState(
        isLowPowerModeEnabled: true, thermalState: .nominal)
    private static let critical = EPUBOffscreenSystemEnergyState(
        isLowPowerModeEnabled: false, thermalState: .critical)
    private static let pause = EPUBOffscreenEnergyPolicy.conservingPause
    private static let poll = EPUBOffscreenEnergyPolicy.deferralPollInterval

    // MARK: - 判断関数

    /// unrestricted はどの状態でも休止も延期もしない。
    func testUnrestrictedNeverPausesOrDefers() {
        let policy = EPUBOffscreenEnergyPolicy.unrestricted
        for state in Self.allStates {
            XCTAssertNil(policy.pauseBeforeJob(in: state))
            XCTAssertFalse(policy.defersStart(in: state))
        }
        XCTAssertFalse(policy.consultsSystemState)
    }

    /// followSystem は低電力モードと serious/critical で休止し、critical だけ延期する。
    func testFollowSystemPausesWhenConservingAndDefersOnlyWhenCritical() {
        let policy = EPUBOffscreenEnergyPolicy.followSystem
        XCTAssertTrue(policy.consultsSystemState)
        XCTAssertNil(policy.pauseBeforeJob(in: EPUBOffscreenSystemEnergyState()))
        XCTAssertNil(policy.pauseBeforeJob(
            in: EPUBOffscreenSystemEnergyState(thermalState: .fair)))
        XCTAssertEqual(policy.pauseBeforeJob(in: Self.lowPower), Self.pause)
        XCTAssertEqual(policy.pauseBeforeJob(
            in: EPUBOffscreenSystemEnergyState(thermalState: .serious)), Self.pause)
        XCTAssertEqual(policy.pauseBeforeJob(in: Self.critical), Self.pause)
        for state in Self.allStates {
            XCTAssertEqual(policy.defersStart(in: state), state.thermalState == .critical)
        }
    }

    // MARK: - pacer

    /// 既定の方針ではシステムの状態を読まず、休止もしない。
    func testPacerWithDefaultPolicyNeverReadsStateOrSleeps() async throws {
        let state = FakeEnergyState()
        state.state = Self.critical
        let recorder = PauseRecorder()
        let pacer = recorder.makePacer(state: state, policy: .unrestricted)

        try await pacer.waitUntilStartAllowed(isAborted: { false })
        try await pacer.pauseBeforeJobIfNeeded()

        XCTAssertEqual(state.readCount, 0)
        XCTAssertEqual(recorder.pauses, [])
    }

    /// followSystem でも省エネが求められていなければ休止を呼ばない(0 秒の
    /// 休止すら入れない)。
    func testPacerFollowSystemWithoutConservationDoesNotSleep() async throws {
        let state = FakeEnergyState()
        let recorder = PauseRecorder()
        let pacer = recorder.makePacer(state: state, policy: .followSystem)

        try await pacer.waitUntilStartAllowed(isAborted: { false })
        try await pacer.pauseBeforeJobIfNeeded()

        XCTAssertEqual(state.readCount, 2)
        XCTAssertEqual(recorder.pauses, [])
    }

    /// critical の間は開始を延期し、回復した瞬間に抜ける。
    func testPacerDefersStartUntilStateLeavesCritical() async throws {
        let state = FakeEnergyState()
        state.state = Self.critical
        let recorder = PauseRecorder()
        recorder.onPause = { count in
            if count == 2 { state.state = Self.lowPower }
        }
        let pacer = recorder.makePacer(state: state, policy: .followSystem)

        try await pacer.waitUntilStartAllowed(isAborted: { false })
        try await pacer.pauseBeforeJobIfNeeded()

        XCTAssertEqual(recorder.pauses, [Self.poll, Self.poll, Self.pause])
    }

    /// 延期中に方針を unrestricted へ戻すと、状態が critical のままでも抜ける。
    func testPacerDeferralEndsWhenPolicyIsReset() async throws {
        let state = FakeEnergyState()
        state.state = Self.critical
        let recorder = PauseRecorder()
        let pacer = recorder.makePacer(state: state, policy: .followSystem)
        recorder.onPause = { _ in pacer.policy = .unrestricted }

        try await pacer.waitUntilStartAllowed(isAborted: { false })

        XCTAssertEqual(recorder.pauses, [Self.poll])
    }

    /// 延期中に呼び出し元が中断(invalidate)されると、状態を読み直さずに抜ける。
    func testPacerDeferralEndsWhenCallerIsAborted() async throws {
        let state = FakeEnergyState()
        state.state = Self.critical
        let recorder = PauseRecorder()
        let pacer = recorder.makePacer(state: state, policy: .followSystem)
        var aborted = false
        recorder.onPause = { _ in aborted = true }

        try await pacer.waitUntilStartAllowed(isAborted: { aborted })

        XCTAssertEqual(recorder.pauses, [Self.poll])
        XCTAssertEqual(state.readCount, 1)
    }

    /// 延期中のキャンセルは、差し替えた sleep が気づかなくても投げる。
    func testPacerDeferralThrowsOnCancellation() async {
        let state = FakeEnergyState()
        state.state = Self.critical
        let recorder = PauseRecorder()
        let pacer = recorder.makePacer(state: state, policy: .followSystem)
        let task = Task { @MainActor in
            try await pacer.waitUntilStartAllowed(isAborted: { false })
        }
        recorder.onPause = { _ in task.cancel() }

        let result = await task.result

        XCTAssertThrowsError(try result.get()) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(recorder.pauses, [Self.poll])
    }

    // MARK: - census(実 WebKit)

    /// 既定の方針の census は休止を一度も入れず、システムの状態も読まない。
    func testCensusWithDefaultPolicyRecordsNoPauses() async throws {
        let state = FakeEnergyState()
        state.state = Self.lowPower
        let recorder = PauseRecorder()
        let census = EPUBPaginationCensus(
            energyPacer: recorder.makePacer(state: state, policy: .unrestricted))
        defer { census.invalidate() }
        let publication = try makeThreeItemPublication(name: "washi-energy-census-default")

        guard let counts = await measure(census, publication) else {
            return try failOrSkipIfWebKitUnavailable()
        }

        XCTAssertEqual(counts.count, 3)
        XCTAssertEqual(recorder.pauses, [])
        XCTAssertEqual(state.readCount, 0)
    }

    /// followSystem でも省エネが求められていなければ休止しない。
    func testCensusFollowSystemWithoutConservationRecordsNoPauses() async throws {
        let state = FakeEnergyState()
        let recorder = PauseRecorder()
        let census = EPUBPaginationCensus(
            energyPacer: recorder.makePacer(state: state, policy: .followSystem))
        defer { census.invalidate() }
        let publication = try makeThreeItemPublication(name: "washi-energy-census-nominal")

        guard let counts = await measure(census, publication) else {
            return try failOrSkipIfWebKitUnavailable()
        }

        XCTAssertEqual(counts.count, 3)
        XCTAssertEqual(recorder.pauses, [])
        XCTAssertGreaterThan(state.readCount, 0)
    }

    /// 省エネ時は WebKit で読み込む項目ごとに 1 回休み(この本は全項目リフロー
    /// なので項目数に一致)、ページ数は unrestricted と同一。
    func testCensusFollowSystemPausesOncePerLoadedItemWithIdenticalCounts() async throws {
        let state = FakeEnergyState()
        state.state = Self.lowPower
        let recorder = PauseRecorder()
        let paced = EPUBPaginationCensus(
            energyPacer: recorder.makePacer(state: state, policy: .followSystem))
        let unrestricted = EPUBPaginationCensus()
        defer {
            paced.invalidate()
            unrestricted.invalidate()
        }
        let publication = try makeThreeItemPublication(name: "washi-energy-census-paced")

        guard let baseline = await measure(unrestricted, publication) else {
            return try failOrSkipIfWebKitUnavailable()
        }
        let counts = await measure(paced, publication)

        XCTAssertEqual(counts, Optional(baseline))
        XCTAssertEqual(paced.loadedItemCount, 3)
        XCTAssertEqual(recorder.pauses, Array(repeating: Self.pause, count: 3))
    }

    /// critical の間は census を始めず、回復を報告した時点で始める(回復後は
    /// 省エネも求められていないので項目の休止はない)。結果は同一。
    func testCensusFollowSystemDefersStartWhileCritical() async throws {
        let state = FakeEnergyState()
        state.state = Self.critical
        let recorder = PauseRecorder()
        recorder.onPause = { count in
            if count == 2 { state.state = EPUBOffscreenSystemEnergyState() }
        }
        let paced = EPUBPaginationCensus(
            energyPacer: recorder.makePacer(state: state, policy: .followSystem))
        let unrestricted = EPUBPaginationCensus()
        defer {
            paced.invalidate()
            unrestricted.invalidate()
        }
        let publication = try makeThreeItemPublication(name: "washi-energy-census-critical")

        guard let baseline = await measure(unrestricted, publication) else {
            return try failOrSkipIfWebKitUnavailable()
        }
        let counts = await measure(paced, publication)

        XCTAssertEqual(counts, Optional(baseline))
        XCTAssertEqual(recorder.pauses, [Self.poll, Self.poll])
    }

    /// 延期中の invalidate は実測を始めさせない: 再確認のたびに中断を見るので、
    /// 状態が critical のままでも 1 回の再確認で抜け、WebKit を作らない。
    func testInvalidationDuringCriticalDeferralDoesNotStartCensus() async throws {
        let state = FakeEnergyState()
        state.state = Self.critical
        let recorder = PauseRecorder()
        let census = EPUBPaginationCensus(
            energyPacer: recorder.makePacer(state: state, policy: .followSystem))
        recorder.onPause = { _ in census.invalidate() }
        let publication = try makeThreeItemPublication(name: "washi-energy-census-invalidate")
        let metrics = makeMetrics()

        let result = await census.measure(
            publication: publication, optionsJSON: metrics.censusOptionsJSON,
            contentSize: metrics.contentSize, resuming: [])

        XCTAssertFalse(result.isComplete)
        XCTAssertEqual(result.counts, [])
        XCTAssertEqual(census.loadedItemCount, 0)
        XCTAssertFalse(census.hasLiveWebView)
        XCTAssertEqual(recorder.pauses, [Self.poll])
    }

    /// 実行中の方針変更は次の項目から効く: 1 項目目の休止で unrestricted へ
    /// 戻すと残りの項目は休まない。
    func testCensusPolicyChangeAppliesToSubsequentItems() async throws {
        let state = FakeEnergyState()
        state.state = Self.lowPower
        let recorder = PauseRecorder()
        let pacer = recorder.makePacer(state: state, policy: .followSystem)
        let census = EPUBPaginationCensus(energyPacer: pacer)
        defer { census.invalidate() }
        recorder.onPause = { _ in pacer.policy = .unrestricted }
        let publication = try makeThreeItemPublication(name: "washi-energy-census-switch")

        guard let counts = await measure(census, publication) else {
            return try failOrSkipIfWebKitUnavailable()
        }

        XCTAssertEqual(counts.count, 3)
        XCTAssertEqual(recorder.pauses, [Self.pause])
        XCTAssertEqual(pacer.policy, .unrestricted)
    }

    // MARK: - サムネイル(実 WebKit)

    /// 既定の方針ではジョブの間に休止を入れない。
    func testThumbnailRendererWithDefaultPolicyRecordsNoPauses() async throws {
        let state = FakeEnergyState()
        state.state = Self.lowPower
        let recorder = PauseRecorder()
        let renderer = EPUBScreenThumbnailRenderer(
            publication: try makeThreeItemPublication(name: "washi-energy-thumb-default"),
            energyPacer: recorder.makePacer(state: state, policy: .unrestricted))
        defer { renderer.invalidate() }

        guard await thumbnail(renderer, spineIndex: 0) != nil else {
            return try failOrSkipIfWebKitUnavailable()
        }
        let second = await thumbnail(renderer, spineIndex: 1)
        XCTAssertNotNil(second)

        XCTAssertEqual(recorder.pauses, [])
        XCTAssertEqual(state.readCount, 0)
    }

    /// 省エネ時はジョブごとに 1 回休み、画像は従来どおり返る。
    func testThumbnailRendererFollowSystemPausesOncePerJob() async throws {
        let state = FakeEnergyState()
        state.state = Self.lowPower
        let recorder = PauseRecorder()
        let renderer = EPUBScreenThumbnailRenderer(
            publication: try makeThreeItemPublication(name: "washi-energy-thumb-paced"),
            energyPacer: recorder.makePacer(state: state, policy: .followSystem))
        defer { renderer.invalidate() }

        guard await thumbnail(renderer, spineIndex: 0) != nil else {
            return try failOrSkipIfWebKitUnavailable()
        }
        let second = await thumbnail(renderer, spineIndex: 1)
        XCTAssertNotNil(second)

        XCTAssertEqual(recorder.pauses, Array(repeating: Self.pause, count: 2))
    }

    // MARK: - FXL(WebKit なし)

    /// 全項目が固定レイアウトの本は WebKit を読み込まないので、省エネ時でも項目の
    /// 休止は 0 回。開始の延期(1 秒の再確認)だけは方針どおり入り、配列は同一。
    func testFXLCensusPolicyMatrixWithoutWebKit() async throws {
        let publication = try EPUBFixtures.fxlComic(name: "washi-energy-fxl-matrix")
        let state = FakeEnergyState()
        state.state = EPUBOffscreenSystemEnergyState(
            isLowPowerModeEnabled: true, thermalState: .critical)
        let recorder = PauseRecorder()
        let pacer = recorder.makePacer(state: state, policy: .unrestricted)
        let census = EPUBPaginationCensus(energyPacer: pacer)
        defer { census.invalidate() }
        let metrics = makeMetrics()
        func measureFXL() async -> [Int]? {
            await census.measure(publication: publication, optionsJSON: metrics.censusOptionsJSON,
                                 contentSize: metrics.contentSize)
        }

        let baseline = await measureFXL()
        XCTAssertEqual(baseline, [1, 1, 1])
        XCTAssertEqual(recorder.pauses, [])
        XCTAssertEqual(state.readCount, 0)

        pacer.policy = .followSystem
        state.state = EPUBOffscreenSystemEnergyState()
        let normal = await measureFXL()
        XCTAssertEqual(normal, baseline)
        XCTAssertEqual(recorder.pauses, [])

        state.state = Self.lowPower
        let conserved = await measureFXL()
        XCTAssertEqual(conserved, baseline)
        XCTAssertEqual(recorder.pauses, [])

        state.state = Self.critical
        recorder.onPause = { count in
            XCTAssertFalse(census.hasLiveWebView)
            XCTAssertEqual(census.loadedItemCount, 0)
            if count == 2 { state.state = EPUBOffscreenSystemEnergyState() }
        }
        let deferred = await measureFXL()
        XCTAssertEqual(deferred, baseline)
        XCTAssertEqual(recorder.pauses, [Self.poll, Self.poll])
        XCTAssertEqual(census.loadedItemCount, 0)
        XCTAssertFalse(census.hasLiveWebView)
    }

    /// 測り残しがなければ(完全な prefix で再開)、critical でも延期せず即座に完了する。
    func testCompletePrefixSkipsDeferral() async throws {
        let publication = try EPUBFixtures.fxlComic(name: "washi-energy-fxl-complete")
        let state = FakeEnergyState()
        state.state = Self.critical
        let recorder = PauseRecorder()
        let census = EPUBPaginationCensus(
            energyPacer: recorder.makePacer(state: state, policy: .followSystem))
        defer { census.invalidate() }
        let metrics = makeMetrics()

        let outcome = await census.measure(
            publication: publication, optionsJSON: metrics.censusOptionsJSON,
            contentSize: metrics.contentSize, resuming: [1, 1, 1])

        XCTAssertEqual(outcome, .init(counts: [1, 1, 1], isComplete: true))
        XCTAssertEqual(recorder.pauses, [])
        XCTAssertEqual(state.readCount, 0)
    }

    // MARK: - サムネイル(続き)

    /// 待機中にキャンセルされたジョブは WebKit を作らずに nil を返し、FIFO の各ジョブが
    /// 1 回ずつ休止する。休止はいずれも userInitiated 以上のタスクで呼ばれる。
    func testThumbnailQueuePacesEachCancelledJobWithoutCreatingWebKit() async throws {
        let state = FakeEnergyState()
        state.state = Self.lowPower
        let recorder = PauseRecorder()
        recorder.throwsCancellation = true
        let renderer = EPUBScreenThumbnailRenderer(
            publication: try EPUBFixtures.fxlComic(name: "washi-energy-thumb-cancel"),
            energyPacer: recorder.makePacer(state: state, policy: .followSystem))
        defer { renderer.invalidate() }

        for _ in 0..<3 {
            let image = await thumbnail(renderer, spineIndex: 0)
            XCTAssertNil(image)
            XCTAssertFalse(renderer.hasLiveWebView)
        }

        XCTAssertEqual(recorder.pauses, Array(repeating: Self.pause, count: 3))
        XCTAssertTrue(recorder.priorities.allSatisfy { $0 >= .userInitiated })
    }

    /// FXL のサムネイルも 1 ジョブ 1 回の休止(委譲先のラスタライザは二重に休まない)。
    /// 休止中に方針を unrestricted へ戻すと、次のジョブは休まない。
    func testThumbnailFXLPausesOncePerJobAndRuntimeChangeApplies() async throws {
        let state = FakeEnergyState()
        state.state = Self.lowPower
        let recorder = PauseRecorder()
        let pacer = recorder.makePacer(state: state, policy: .followSystem)
        let renderer = EPUBScreenThumbnailRenderer(
            publication: try EPUBFixtures.fxlComic(name: "washi-energy-thumb-fxl"),
            energyPacer: pacer)
        defer { renderer.invalidate() }

        guard let first = await thumbnail(renderer, spineIndex: 0) else {
            return try failOrSkipIfWebKitUnavailable()
        }
        XCTAssertEqual(recorder.pauses, [Self.pause])
        XCTAssertTrue(recorder.priorities.allSatisfy { $0 >= .userInitiated })

        recorder.onPause = { _ in pacer.policy = .unrestricted }
        let changed = await thumbnail(renderer, spineIndex: 1)
        let subsequent = await thumbnail(renderer, spineIndex: 2)

        XCTAssertEqual(changed?.width, first.width)
        XCTAssertNotNil(subsequent)
        XCTAssertEqual(recorder.pauses, [Self.pause, Self.pause])
        XCTAssertEqual(state.readCount, 2)
    }

    // MARK: - 所有者への配線

    /// atlas の公開プロパティは 1 つの pacer の実体で、注入した census がその pacer を
    /// 共有していれば screenPlan の実測が方針どおりに休む。
    func testAtlasSharesPacerWithCensus() async throws {
        let state = FakeEnergyState()
        state.state = Self.lowPower
        let recorder = PauseRecorder()
        let pacer = recorder.makePacer(state: state, policy: .unrestricted)
        let atlas = EPUBScreenAtlas(
            publication: try makeThreeItemPublication(name: "washi-energy-atlas"),
            census: EPUBPaginationCensus(energyPacer: pacer), energyPacer: pacer)
        defer { atlas.invalidate() }
        XCTAssertEqual(atlas.offscreenEnergyPolicy, .unrestricted)

        atlas.offscreenEnergyPolicy = .followSystem
        XCTAssertEqual(pacer.policy, .followSystem)
        guard let plan = await atlas.screenPlan(metrics: makeMetrics()) else {
            return try failOrSkipIfWebKitUnavailable()
        }

        XCTAssertEqual(plan.counts.count, 3)
        XCTAssertEqual(recorder.pauses, Array(repeating: Self.pause, count: 3))
        atlas.offscreenEnergyPolicy = .unrestricted
        XCTAssertEqual(pacer.policy, .unrestricted)
    }

    /// リーダービューの公開プロパティは、census エンジンとサムネイルレンダラへ渡す
    /// pacer の実体を読み書きする(本の差し替えで戻る CensusState には置かない)。
    func testReaderViewPolicyIsBackedBySharedPacer() {
        let view = EPUBReaderView(frame: .zero)
        XCTAssertEqual(view.offscreenEnergyPolicy, .unrestricted)
        XCTAssertEqual(view.offscreenEnergyPacer.policy, .unrestricted)

        view.offscreenEnergyPolicy = .followSystem
        XCTAssertEqual(view.offscreenEnergyPacer.policy, .followSystem)
        view.offscreenEnergyPacer.policy = .unrestricted
        XCTAssertEqual(view.offscreenEnergyPolicy, .unrestricted)
    }

    // MARK: - 補助

    private static var allStates: [EPUBOffscreenSystemEnergyState] {
        let thermal: [ProcessInfo.ThermalState] = [.nominal, .fair, .serious, .critical]
        return thermal.flatMap { state in
            [false, true].map {
                EPUBOffscreenSystemEnergyState(isLowPowerModeEnabled: $0, thermalState: state)
            }
        }
    }

    private func measure(_ census: EPUBPaginationCensus,
                         _ publication: EPUBPublication) async -> [Int]? {
        let metrics = makeMetrics()
        return await census.measure(
            publication: publication, optionsJSON: metrics.censusOptionsJSON,
            contentSize: metrics.contentSize)
    }

    private func thumbnail(_ renderer: EPUBScreenThumbnailRenderer,
                           spineIndex: Int) async -> CGImage? {
        let metrics = makeMetrics()
        return await renderer.thumbnail(
            spineIndex: spineIndex, pageInItem: 0,
            optionsJSON: metrics.themedOptionsJSON(isDark: false),
            contentSize: metrics.contentSize, snapshotWidth: 120)
    }

    private func makeMetrics() -> EPUBScreenMetrics {
        var settings = EPUBReaderSettings()
        settings.insets = .zero
        return EPUBScreenMetrics(
            viewportSize: CGSize(width: 420, height: 600), settings: settings)
    }

    /// リフロー 3 項目の本(全項目を WebKit で読み込むので、休止の回数が項目数に一致する)。
    private func makeThreeItemPublication(name: String) throws -> EPUBPublication {
        let opf = """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0"
                     unique-identifier="uid">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="uid">urn:uuid:energy-three-items</dc:identifier>
                <dc:title>Energy policy fixture</dc:title>
                <dc:language>en</dc:language>
              </metadata>
              <manifest>
                <item id="a" href="text/a.xhtml" media-type="application/xhtml+xml"/>
                <item id="b" href="text/b.xhtml" media-type="application/xhtml+xml"/>
                <item id="c" href="text/c.xhtml" media-type="application/xhtml+xml"/>
              </manifest>
              <spine>
                <itemref idref="a"/>
                <itemref idref="b"/>
                <itemref idref="c"/>
              </spine>
            </package>
            """
        func xhtml(_ title: String) -> Data {
            Data("""
                <?xml version="1.0" encoding="UTF-8"?>
                <html xmlns="http://www.w3.org/1999/xhtml">
                  <head><title>\(title)</title></head>
                  <body><p>\(title) spine item.</p></body>
                </html>
                """.utf8)
        }
        let entries: [(name: String, data: Data)] = [
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", Data(EPUBFixtures.containerXML.utf8)),
            ("OEBPS/package.opf", Data(opf.utf8)),
            ("OEBPS/text/a.xhtml", xhtml("First")),
            ("OEBPS/text/b.xhtml", xhtml("Second")),
            ("OEBPS/text/c.xhtml", xhtml("Third")),
        ]
        return try EPUBFixtures.publication(entries, name: name)
    }
}
