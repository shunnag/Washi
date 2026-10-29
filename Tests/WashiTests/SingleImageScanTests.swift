import AppKit
import WebKit
import XCTest
@testable import Washi
@testable import WashiCore

final class SingleImageScanTests: XCTestCase {
    /// 後半が不正でも、可視本文や別画像を見つけた時点で否定できる。
    func testScanAbortsAtVisibleTextOrDifferentImage() throws {
        for body in ["<p>本文</p><img src='a.png'/>",
                     "<img src='a.png'/><img src='b.png'/>",
                     "<img/><img src='a.png'/>"] {
            let data = Data(("<html><body>" + body + String(repeating: "<", count: 100_000)).utf8)
            XCTAssertTrue(try WashiXML.rejectsSingleImageDocument(data))
        }
    }

    /// 隠れた代替文・SVG 説明・同じ参照の複製を早期否定しない。
    func testScanAndDOMPreserveImagePageVariants() throws {
        let cases: [(String, Bool)] = [
            ("<p>visible</p><img src='a.png'/>", false),
            ("<img src='a.png'/><img src='b.png'/>", false),
            ("<img src='a.png'/><div hidden='hidden'>alt</div><img src='a.png'/>", true),
            ("<style>p {display:none}</style><script>ignored</script><img src='a.png'/>", true),
            ("<div style='DISPLAY: none !important'><span>alt</span></div><img src='a.png'/>", true),
            ("<svg xmlns='http://www.w3.org/2000/svg'><title>alt</title><desc>alt</desc><image href='a.png'/></svg>", true),
            ("<svg xmlns='http://www.w3.org/2000/svg' xmlns:q='http://www.w3.org/1999/xlink'><image q:href='a.png'/></svg>", true),
            ("<img src='a.png'/><p>&nbsp;</p>", true),
            ("<img src='a.png'/><p><![CDATA[visible]]></p>", false),
            ("<img src='a.png'/><p>&#x3000;</p>", true),
            ("<img src='a.png'/><div hidden='hidden'><img src='b.png'/></div>", false),
            ("<img src='a.png'/><img src=' '/>", false),
        ]
        for (body, expected) in cases {
            let publication = try EPUBFixtures.singleSpine(bodyHTML: body)
            XCTAssertEqual(publication.isSingleImageItem(atSpineIndex: 0), expected, body)
            XCTAssertEqual(try publication.fixedLayoutInfo(forSpineIndex: 0).simpleImagePath != nil,
                           expected, body)
        }
    }

    func testScanDefersEncodingAndEntityRecoveryToDOM() throws {
        let xml = "<html><body><img src='a.png'/><p>visible</p></body></html>"
        XCTAssertFalse(try WashiXML.rejectsSingleImageDocument(try XCTUnwrap(xml.data(using: .utf16))))
        XCTAssertFalse(try WashiXML.rejectsSingleImageDocument(
            Data("<html><body>&nbsp;<img src='a.png'/></body></html>".utf8)))
        XCTAssertThrowsError(try WashiXML.rejectsSingleImageDocument(Data("""
            <!DOCTYPE html [<!ENTITY bomb "&bomb;">]><html><body>text</body></html>
            """.utf8)))
    }

    func testCachedLookupDoesNotComputeAndRetainsFalse() throws {
        let publication = try EPUBFixtures.singleSpine(bodyHTML: "<p>text</p>")
        XCTAssertNil(publication.cachedSingleImageItem(atSpineIndex: 0))
        XCTAssertFalse(publication.isSingleImageItem(atSpineIndex: 0))
        XCTAssertEqual(publication.cachedSingleImageItem(atSpineIndex: 0), false)
        XCTAssertNil(publication.cachedSingleImageItem(atSpineIndex: -1))
    }
}

@MainActor
final class SingleImageSpineLoadTests: XCTestCase {
    private func makeView() async -> EPUBReaderView {
        let view = EPUBReaderView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.settings.insets = EPUBReaderInsets(top: 20, left: 40, bottom: 20, right: 40)
        view.settings.spreadInsets = nil
        view.networkLockdown = NetworkLockdownRuleList(compile: { throw URLError(.unknown) })
        await view.networkLockdown.prepare()
        return view
    }

    private func book(_ reader: ImageScanThreadReader) throws -> EPUBPublication {
        try EPUBPublication(url: URL(fileURLWithPath: "/unused.epub"), reader: reader)
    }

    /// 未判定でもロードを同期発行し、画像の版面だけを初回 setup 前に確定する。
    func testLoadDoesNotWaitForClassificationAndCachedVisitNeedsNoRead() async throws {
        let reader = try ImageScanThreadReader()
        let publication = try book(reader)
        let view = await makeView()
        let gate = ImageClassificationReadGate()
        reader.beforeBodyRead = { gate.block() }
        defer { view.unload(); gate.release() }
        let navigation = try makeNavigationTokenForTest()
        var loads = 0
        view.spineLoadHandler = { _ in loads += 1; return navigation }
        view.load(publication: publication, at: publication.locator(forSpineIndex: 0, progression: 0.75))
        XCTAssertEqual(loads, 1, "未キャッシュの判定がロード発行を遅らせない")
        XCTAssertTrue(view.currentNavigation === navigation)
        XCTAssertNil(view.networkLockdownTask)
        await fulfillment(of: [gate.started], timeout: 3)
        XCTAssertFalse(view.isImageOnlyItem)
        XCTAssertNotEqual(view.contentFrame, view.bounds)
        let web = try view.firstWebView()
        view.webView(web, didCommit: navigation)
        let generation = view.spineLoadGeneration
        let layout = Task { await view.prepareImageOnlyItemForSetup(in: web, generation: generation) }
        gate.release()
        let ready = await layout.value
        XCTAssertTrue(ready)
        XCTAssertTrue(view.isImageOnlyItem)
        XCTAssertEqual(web.frame, view.bounds)
        XCTAssertEqual(view.spineLoad.pendingRestoreLocator?.progression, 0.75)
        XCTAssertEqual(loads, 1, "判定の完了ではナビゲーションを再発行しない")
        XCTAssertEqual(reader.mainReads, 0)
        XCTAssertTrue(reader.backgroundPriorities.allSatisfy { $0 >= .userInitiated })
        let reads = reader.backgroundReads
        view.loadSpineItem(at: 0, target: .progression(0.5))
        XCTAssertEqual(loads, 2)
        XCTAssertEqual(reader.backgroundReads, reads)
        XCTAssertTrue(view.isImageOnlyItem)
        XCTAssertEqual(view.spineLoad.pendingRestoreLocator?.progression, 0.5)
    }

    /// 初回ロードが nil を返すと、同じ呼び出し内で発行した回復 navigation を保持する。
    func testNilLoadRecoversSynchronouslyWhileClassificationIsBlocked() async throws {
        let reader = try ImageScanThreadReader()
        let publication = try book(reader)
        let view = await makeView()
        let observer = ReaderObservationSpy()
        view.delegate = observer
        let gate = ImageClassificationReadGate()
        reader.beforeBodyRead = { gate.block() }
        defer { view.unload(); gate.release() }
        let navigation = try makeNavigationTokenForTest()
        view.spineLoadHandler = { _ in navigation }
        view.load(publication: publication)
        let original = try XCTUnwrap(view.spineLoad.imageClassificationTask)
        await fulfillment(of: [gate.started], timeout: 3)
        let generation = view.spineLoadGeneration
        view.spineLoad.recovery.settledLocator = publication.locator(forSpineIndex: 0, progression: 0.4)
        let recovery = try makeNavigationTokenForTest()
        var loads = 0
        view.spineLoadHandler = { _ in loads += 1; return loads == 1 ? nil : recovery }
        view.loadSpineItem(at: 0, target: .progression(0.9))
        XCTAssertEqual(loads, 2)
        XCTAssertEqual(observer.failures.count, 1)
        XCTAssertTrue(view.currentNavigation === recovery)
        XCTAssertTrue(view.spineLoad.recovery.isRecoveryLoad)
        XCTAssertEqual(view.spineLoadGeneration, generation + 2)
        XCTAssertEqual(view.currentLocator.progression, 0.4)
        gate.release()
        _ = await original.value
        XCTAssertEqual(loads, 2)
        XCTAssertTrue(view.currentNavigation === recovery)
        let path = publication.readingOrder[0].resolvedContainerPath
        XCTAssertEqual(view.spineNavigationGate.disposition(for: path, navigationType: .other), .cancelAbandonedLoad)
        XCTAssertEqual(view.spineNavigationGate.disposition(for: path, navigationType: .other), .allowExpectedLoad)
        XCTAssertEqual(view.spineNavigationGate.disposition(for: path, navigationType: .other), .routeThroughReader)
    }

    /// 終了後に古い判定が完了しても、同じパスの新しい発行・policy 期待値を上書きしない。
    func testSamePathLoadAfterTerminationDoesNotWaitForOldClassification() async throws {
        for terminationCount in 1...4 {
            let reader = try ImageScanThreadReader()
            let publication = try book(reader)
            let view = await makeView()
            view.isHidden = true
            let gate = ImageClassificationReadGate()
            reader.beforeBodyRead = { gate.block() }
            defer { view.unload(); gate.release() }
            let first = try makeNavigationTokenForTest(), second = try makeNavigationTokenForTest()
            var requests: [URLRequest] = []
            view.spineLoadHandler = { request in
                requests.append(request)
                return requests.count == 1 ? first : second
            }
            view.load(publication: publication)
            XCTAssertEqual(requests.count, 1)
            let classification = try XCTUnwrap(view.spineLoad.imageClassificationTask)
            let web = try view.firstWebView()
            let generation = view.spineLoadGeneration
            await fulfillment(of: [gate.started], timeout: 3)
            let oldLayout = Task { await view.prepareImageOnlyItemForSetup(in: web, generation: generation) }
            let now = Date(timeIntervalSinceReferenceDate: 6_000)
            for _ in 0..<terminationCount { view.handleWebContentProcessTermination(at: now) }
            XCTAssertTrue(classification.isCancelled)
            XCTAssertEqual(view.hasPendingWebContentReload, terminationCount < 4)
            view.loadSpineItem(at: 0, target: .progression(0.6))
            XCTAssertEqual(requests.count, 2)
            XCTAssertEqual(requests.first?.url, requests.last?.url)
            XCTAssertTrue(view.currentNavigation === second)
            XCTAssertFalse(view.hasPendingWebContentReload)
            let path = publication.readingOrder[0].resolvedContainerPath
            XCTAssertEqual(view.spineNavigationGate.disposition(for: path, navigationType: .other), .allowExpectedLoad)
            gate.release()
            let oldReady = await oldLayout.value
            XCTAssertFalse(oldReady)
            _ = await classification.value
            XCTAssertEqual(requests.count, 2)
            XCTAssertTrue(view.currentNavigation === second)
            XCTAssertEqual(view.currentLocator.progression, 0.6)
            XCTAssertEqual(view.spineNavigationGate.disposition(for: path, navigationType: .other), .routeThroughReader)
        }
    }

    /// abandon は世代を変えないので、取消済み判定の状態も確認して版面更新を止める。
    func testAbandonDiscardsClassificationInSameGeneration() async throws {
        let reader = try ImageScanThreadReader()
        let publication = try book(reader)
        let view = await makeView()
        let gate = ImageClassificationReadGate()
        reader.beforeBodyRead = { gate.block() }
        defer { view.unload(); gate.release() }
        let navigation = try makeNavigationTokenForTest()
        view.spineLoadHandler = { _ in navigation }
        view.load(publication: publication)
        let web = try view.firstWebView()
        let generation = view.spineLoadGeneration
        await fulfillment(of: [gate.started], timeout: 3)
        let layout = Task { await view.prepareImageOnlyItemForSetup(in: web, generation: generation) }
        view.abandonSpineLoad()
        XCTAssertEqual(view.spineLoadGeneration, generation)
        gate.release()
        let ready = await layout.value
        XCTAssertFalse(ready)
        XCTAssertFalse(view.isImageOnlyItem)
        XCTAssertNil(view.currentNavigation)
        XCTAssertFalse(view.spineLoad.isLoadingSpineItem)
    }

    /// 閉じた本の遅い判定は、すでに発行したロードを再発行せず版面にも触れない。
    func testUnloadDuringClassificationDiscardsPendingLayout() async throws {
        let reader = try ImageScanThreadReader()
        let publication = try book(reader)
        let view = await makeView()
        let gate = ImageClassificationReadGate()
        reader.beforeBodyRead = { gate.block() }
        defer { view.unload(); gate.release() }
        let first = try makeNavigationTokenForTest(), second = try makeNavigationTokenForTest()
        var loads = 0
        view.spineLoadHandler = { _ in loads += 1; return loads == 1 ? first : second }
        view.load(publication: publication)
        XCTAssertEqual(loads, 1)
        let web = try view.firstWebView()
        let generation = view.spineLoadGeneration
        await fulfillment(of: [gate.started], timeout: 3)
        let layout = Task { await view.prepareImageOnlyItemForSetup(in: web, generation: generation) }
        view.unload()
        gate.release()
        let ready = await layout.value
        XCTAssertFalse(ready)
        XCTAssertEqual(loads, 1)
        XCTAssertNil(view.publication)
        XCTAssertEqual(reader.mainReads, 0)
    }

    func testBookReplacementDoesNotApplyOldImageLayout() async throws {
        let reader = try ImageScanThreadReader()
        let publication = try book(reader)
        let view = await makeView()
        let gate = ImageClassificationReadGate()
        reader.beforeBodyRead = { gate.block() }
        defer { view.unload(); gate.release() }
        let first = try makeNavigationTokenForTest(), second = try makeNavigationTokenForTest()
        var loads = 0
        view.spineLoadHandler = { _ in loads += 1; return loads == 1 ? first : second }
        view.load(publication: publication)
        let oldWeb = try view.firstWebView()
        let generation = view.spineLoadGeneration
        await fulfillment(of: [gate.started], timeout: 3)
        let layout = Task { await view.prepareImageOnlyItemForSetup(in: oldWeb, generation: generation) }
        let replacement = try EPUBFixtures.singleSpine(bodyHTML: "<p>replacement</p>")
        view.load(publication: replacement)
        XCTAssertEqual(loads, 2)
        let navigation = view.currentNavigation
        gate.release()
        let ready = await layout.value
        XCTAssertFalse(ready)
        XCTAssertTrue(view.publication === replacement)
        XCTAssertTrue(view.currentNavigation === navigation)
        XCTAssertFalse(view.isImageOnlyItem)
        XCTAssertNotEqual(view.contentFrame, view.bounds)
    }

    /// 古い setup は判定待ちの間に置き換わったら、新しい setup の帳簿に触れない。
    func testSupersededSetupCannotClearNewSetupState() async throws {
        let reader = try ImageScanThreadReader()
        let publication = try book(reader)
        let view = await makeView()
        let gate = ImageClassificationReadGate()
        reader.beforeBodyRead = { gate.block() }
        defer { view.unload(); gate.release() }
        let initialNavigation = try makeNavigationTokenForTest()
        view.spineLoadHandler = { _ in initialNavigation }
        view.load(publication: publication)
        let generation = view.spineLoadGeneration
        await fulfillment(of: [gate.started], timeout: 3)
        let entered = expectation(description: "旧 setup の開始")
        let setup = Task {
            entered.fulfill()
            await view.runSetup(preserveProgression: false, generation: generation)
        }
        await fulfillment(of: [entered], timeout: 3)
        let nextNavigation = try makeNavigationTokenForTest()
        view.spineLoadHandler = { _ in nextNavigation }
        view.loadSpineItem(at: 0, target: .progression(0.7))
        let navigation = view.currentNavigation
        view.spineLoad.isSettingUp = true
        view.repagination.pendingRepaginate = true
        gate.release()
        await setup.value
        XCTAssertTrue(view.currentNavigation === navigation)
        XCTAssertTrue(view.spineLoad.isSettingUp)
        XCTAssertTrue(view.repagination.pendingRepaginate)
        XCTAssertEqual(view.currentLocator.progression, 0.7)
    }
}

/// 最初の読み取りだけを明示的に止め、主スレッドや固定 sleep に依存せず順序を検証する。
private final class ImageClassificationReadGate: @unchecked Sendable {
    let started = XCTestExpectation(description: "画像判定の読み取り開始")
    private let semaphore = DispatchSemaphore(value: 0)

    func block() {
        started.fulfill()
        _ = semaphore.wait(timeout: .now() + 5)
    }

    func release() { semaphore.signal() }
}

/// 読み取りスレッドだけを記録する。全可変状態をロック内で扱う。
private final class ImageScanThreadReader: ContainerReader, @unchecked Sendable {
    private let base: ZipContainerReader
    private let lock = NSLock()
    private var reads = (main: 0, background: 0)
    private var priorities: [TaskPriority] = []
    private var readHook: (@Sendable () -> Void)?
    var beforeBodyRead: (@Sendable () -> Void)? {
        get { lock.withLock { readHook } }
        set { lock.withLock { readHook = newValue } }
    }
    var mainReads: Int { lock.withLock { reads.main } }
    var backgroundReads: Int { lock.withLock { reads.background } }
    var backgroundPriorities: [TaskPriority] { lock.withLock { priorities } }

    init() throws {
        var entries = EPUBFixtures.singleSpineEntries(bodyHTML: "<img src='a.png'/>")
        let index = entries.firstIndex { $0.name.hasSuffix(".opf") }!
        entries[index].data = Data(String(decoding: entries[index].data, as: UTF8.self)
            .replacingOccurrences(of: "<spine>", with: "<spine page-progression-direction='ltr'>").utf8)
        base = ZipContainerReader(archive: try ZipArchive(data: ZipBuilder.build(entries)))
    }
    var allPaths: [String] { base.allPaths }
    func exists(_ path: String) -> Bool { base.exists(path) }
    func read(_ path: String) throws -> Data {
        if path.hasSuffix(".xhtml") {
            let hook = lock.withLock {
                if Thread.isMainThread {
                    reads.main += 1
                } else {
                    reads.background += 1
                    priorities.append(Task.currentPriority)
                }
                let hook = readHook
                readHook = nil
                return hook
            }
            hook?()
        }
        return try base.read(path)
    }
}
