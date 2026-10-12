import AppKit
import XCTest
@testable import Washi
@testable import WashiCore

/// 連続スクロールの scroll イベント(pageChanged)ごとにメインスレッドで繰り返していた
/// 仕事を省いても、状態・delegate 通知が変わらないことを確かめる:
/// (1) page-list の平坦化と spine 解決は本ごとに 1 回、(2) 同じ markers の
/// applySetupResult は読み飛ばす、(3) 控えを使わない場面では撮影 Task を起こさない。
@MainActor
final class ContinuousScrollEventCostTests: XCTestCase {
    // MARK: - フィクスチャ

    /// `chapters` 章の本に、入れ子の page-list を `entryCount` 項目持たせる。
    /// 7 項目ごとに spine 外の href、11 項目ごとにリンクの無い見出し項目を混ぜる
    /// (どちらも spine 番号に解決できず、フォールバックの候補にならない)
    private func makeNestedPageListPublication(entryCount: Int, chapters: Int,
                                               name: String) throws -> EPUBPublication {
        let manifest = (0..<chapters).map {
            "<item id=\"c\($0)\" href=\"text/c\($0).xhtml\" media-type=\"application/xhtml+xml\"/>"
        }.joined()
        let spine = (0..<chapters).map { "<itemref idref=\"c\($0)\"/>" }.joined()
        let opf = """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="uid">urn:uuid:nested-page-list</dc:identifier>
                <dc:title>Nested page list</dc:title><dc:language>en</dc:language>
              </metadata>
              <manifest>
                <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
                \(manifest)
              </manifest>
              <spine>\(spine)</spine>
            </package>
            """
        var list = ""
        var number = 0
        let perChapter = max(1, entryCount / chapters)
        for chapter in 0..<chapters {
            let end = chapter == chapters - 1 ? entryCount : (chapter + 1) * perChapter
            list += "<li><a href=\"text/c\(chapter).xhtml\">\(number)</a><ol>"
            number += 1
            var depth = 0
            while number < end {
                if number % 11 == 0 {
                    list += "<li><span>\(number)</span></li>"
                } else if number % 7 == 0 {
                    list += "<li><a href=\"missing/m\(number).xhtml\">\(number)</a></li>"
                } else if number % 5 == 0, depth < 3 {
                    // さらに入れ子にする(閉じるのは章の末尾)
                    list += "<li><a href=\"text/c\(chapter).xhtml#p\(number)\">\(number)</a><ol>"
                    depth += 1
                } else {
                    list += "<li><a href=\"text/c\(chapter).xhtml#p\(number)\">\(number)</a></li>"
                }
                number += 1
            }
            list += String(repeating: "</ol></li>", count: depth)
            list += "</ol></li>"
        }
        let nav = """
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><body>
              <nav epub:type="toc"><ol><li><a href="text/c0.xhtml">Start</a></li></ol></nav>
              <nav epub:type="page-list"><ol>\(list)</ol></nav>
            </body></html>
            """
        var entries: [(name: String, data: Data)] = [
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", Data(EPUBFixtures.containerXML.utf8)),
            ("OEBPS/package.opf", Data(opf.utf8)),
            ("OEBPS/nav.xhtml", Data(nav.utf8)),
        ]
        for chapter in 0..<chapters {
            entries.append(("OEBPS/text/c\(chapter).xhtml", Data(EPUBFixtures.chapterXHTML(
                title: "c\(chapter)", body: "<p id=\"p\(chapter)\">chapter \(chapter)</p>").utf8)))
        }
        return try EPUBFixtures.publication(entries, name: name)
    }

    /// 本をビューに結びつける(WebKit は作らない)
    private func makeView(_ publication: EPUBPublication) -> EPUBReaderView {
        let view = EPUBReaderView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        view.preparePublication(publication)
        return view
    }

    // MARK: - 旧来の計算(比較用の写し)

    /// 変更前の updateCurrentPrintPage: 呼ばれるたびに page-list を平坦化し、
    /// 項目ごとに spineIndex(forNavItem:) を解く
    private func legacyFlatten(_ items: [EPUBNavItem]) -> [EPUBNavItem] {
        items.flatMap { [$0] + legacyFlatten($0.children) }
    }

    private func legacyPrintPage(_ view: EPUBReaderView, _ publication: EPUBPublication) -> String? {
        let local = view.printPageMarkers.last { $0.page <= view.pageInItem }?.label
        let fallback = legacyFlatten(publication.navigation.pageList).last { item in
            guard let index = publication.spineIndex(forNavItem: item) else { return false }
            return index < view.currentSpineIndex
        }?.title
        return local ?? fallback
    }

    // MARK: - (1) page-list の解決を本ごとに 1 回へ

    func testUpdateCurrentPrintPageMatchesUncachedComputationOnNestedPageList() throws {
        let publication = try makeNestedPageListPublication(entryCount: 3_000, chapters: 8,
                                                            name: "washi-nested-page-list")
        let flat = legacyFlatten(publication.navigation.pageList)
        XCTAssertEqual(flat.count, 3_000, "入れ子の page-list が全て平坦化される")
        XCTAssertTrue(flat.contains { publication.spineIndex(forNavItem: $0) == nil },
                      "解決できない項目を含むフィクスチャであること")
        let view = makeView(publication)
        XCTAssertEqual(view.printPageLabels, flat.map(\.title))

        let markerSets: [[EPUBReaderView.PrintPageMarker]] = [
            [],
            [.init(label: "L0", page: 0), .init(label: "L3", page: 3)],
            [.init(label: "L9", page: 9)],
        ]
        var compared = 0
        for spineIndex in [0, 1, 3, 7, 8, 50] {
            for pageInItem in [0, 2, 5] {
                for markers in markerSets {
                    view.currentSpineIndex = spineIndex
                    view.pageInItem = pageInItem
                    view.printPageMarkers = markers
                    view.updateCurrentPrintPage()
                    XCTAssertEqual(view.currentPrintPage, legacyPrintPage(view, publication),
                                   "spine \(spineIndex) page \(pageInItem) markers \(markers)")
                    compared += 1
                }
            }
        }
        XCTAssertEqual(compared, 54)
        // 章頭より前(spine 0、markers なし)は従来どおり nil
        view.currentSpineIndex = 0
        view.printPageMarkers = []
        view.updateCurrentPrintPage()
        XCTAssertNil(view.currentPrintPage)
    }

    /// 本を差し替えると解決済みの一覧も差し替わり、本が無ければ空になる。
    func testResolvedPrintPageListFollowsPublication() throws {
        let first = try makeNestedPageListPublication(entryCount: 30, chapters: 3, name: "washi-page-list-a")
        let second = try makeNestedPageListPublication(entryCount: 12, chapters: 2, name: "washi-page-list-b")
        let view = makeView(first)
        XCTAssertEqual(view.printPageLabels.count, 30)
        XCTAssertNotNil(view.resolvedPrintPageListCache)
        view.preparePublication(second)
        XCTAssertEqual(view.printPageLabels.count, 12)
        view.preparePublication(nil)
        XCTAssertEqual(view.printPageLabels, [])
        view.currentSpineIndex = 5
        view.updateCurrentPrintPage()
        XCTAssertNil(view.currentPrintPage)
    }

    /// マイクロベンチマーク(壁時計には assert しない): 3,000 項目の入れ子
    /// page-list で、旧来の毎回解決と解決済み一覧の updateCurrentPrintPage を比べる。
    /// 旧来は末尾から「現在 spine より前」の項目が見つかるまで解決するので、
    /// 先頭の章(全項目を解決する最悪)と末尾の章(直前の章まで)の両方を測る。
    func testUpdateCurrentPrintPageMicroBenchmark() throws {
        let publication = try makeNestedPageListPublication(entryCount: 3_000, chapters: 8,
                                                            name: "washi-page-list-bench")
        let view = makeView(publication)
        view.printPageMarkers = []
        let iterations = 200
        func perCall(_ duration: Duration, _ count: Int) -> String {
            let seconds = Double(duration.components.seconds)
                + Double(duration.components.attoseconds) / 1e18
            return String(format: "%.1f µs/call", seconds / Double(count) * 1e6)
        }
        for spineIndex in [0, 7] {
            view.currentSpineIndex = spineIndex
            var legacy: String?
            let legacyStart = ContinuousClock.now
            for _ in 0..<iterations { legacy = legacyPrintPage(view, publication) }
            let legacyElapsed = ContinuousClock.now - legacyStart

            view.resolvedPrintPageListCache = nil
            let firstStart = ContinuousClock.now
            view.updateCurrentPrintPage()
            let firstElapsed = ContinuousClock.now - firstStart

            let cachedStart = ContinuousClock.now
            for _ in 0..<iterations { view.updateCurrentPrintPage() }
            let cachedElapsed = ContinuousClock.now - cachedStart

            XCTAssertEqual(view.currentPrintPage, legacy)
            print("[Washi print-page bench] spine \(spineIndex): legacy \(perCall(legacyElapsed, iterations)); "
                  + "cached first call \(perCall(firstElapsed, 1)); "
                  + "cached steady \(perCall(cachedElapsed, iterations))")
        }
    }

    // MARK: - (2) 同じ markers の applySetupResult を読み飛ばす

    private func pageChanged(markers: [[String: Any]], mode: String = "htb",
                             page: Int = 0) -> [String: Any] {
        ["type": "pageChanged", "page": page, "pageCount": 6, "pagesPerScreen": 1,
         "mode": mode, "progression": 0.25, "printPageMarkers": markers]
    }

    func testPageChangedSkipsSetupResultOnlyForIdenticalMarkers() {
        let view = EPUBReaderView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let delegate = ReaderObservationSpy()
        view.delegate = delegate
        let markersA: [[String: Any]] = [["label": "1", "page": 0], ["label": "2", "page": 3]]
        let markersB: [[String: Any]] = [["label": "1", "page": 0], ["label": "3", "page": 4]]

        view.handleScriptMessage(pageChanged(markers: markersA))
        XCTAssertEqual(view.setupResultApplyCount, 1)
        XCTAssertEqual(view.printPageMarkers, [.init(label: "1", page: 0), .init(label: "2", page: 3)])
        XCTAssertEqual(view.scrolledWheel.mode, "htb")
        let applied = (view.pageCountInItem, view.pagesPerScreen, view.isImagePage,
                       view.firstPageOnRight, view.columnAxisSupported)

        // 同じ章の scroll イベント: markers・mode が同じなら適用しない
        view.handleScriptMessage(pageChanged(markers: markersA, page: 2))
        view.handleScriptMessage(pageChanged(markers: markersA, page: 4))
        XCTAssertEqual(view.setupResultApplyCount, 1, "同じ markers では applySetupResult を省く")
        XCTAssertEqual(view.printPageMarkers, [.init(label: "1", page: 0), .init(label: "2", page: 3)])
        XCTAssertEqual((view.pageCountInItem, view.pagesPerScreen, view.isImagePage,
                        view.firstPageOnRight, view.columnAxisSupported) == applied, true,
                       "省いても状態は適用時と同じ")
        XCTAssertEqual(view.pageInItem, 4)
        XCTAssertEqual(delegate.moveCount, 3, "delegate の didMoveTo は従来どおり毎回届く")

        // markers が変われば適用する
        view.handleScriptMessage(pageChanged(markers: markersB))
        XCTAssertEqual(view.setupResultApplyCount, 2)
        XCTAssertEqual(view.printPageMarkers, [.init(label: "1", page: 0), .init(label: "3", page: 4)])

        // markers が同じでも mode が変われば適用する(scrolledWheel の方向を保つため)
        view.handleScriptMessage(pageChanged(markers: markersB, mode: "vrl"))
        XCTAssertEqual(view.setupResultApplyCount, 3)
        XCTAssertEqual(view.scrolledWheel.mode, "vrl")
        view.handleScriptMessage(pageChanged(markers: markersB, mode: "vrl"))
        XCTAssertEqual(view.setupResultApplyCount, 3)

        // 壊れた値を含む markers は適用後に捨てられるので、同値なら同じく省く
        view.handleScriptMessage(pageChanged(
            markers: markersB + [["label": "", "page": 1], ["label": "x", "page": -1]], mode: "vrl"))
        XCTAssertEqual(view.setupResultApplyCount, 3)

        // pageChanged の契約外の鍵(setup の戻り値)が載っていれば省かない
        var setupLike = pageChanged(markers: markersB, mode: "vrl")
        setupLike["supportsColumnAxis"] = true
        view.handleScriptMessage(setupLike)
        XCTAssertEqual(view.setupResultApplyCount, 4)
        XCTAssertEqual(delegate.moveCount, 8, "読み飛ばしても didMoveTo の回数は変わらない")
    }

    /// 連続スクロール文書の pageChanged を繰り返し受けても、delegate への通知の
    /// 種類・回数・値・順序は読み飛ばしの前と同じ(印刷ページ → 移動の順、移動は毎回)。
    func testRepeatedMessagesKeepDelegateFrequencyValuesAndOrder() throws {
        let view = EPUBReaderView(frame: .zero)
        view.preparePublication(try scrollPublication(
            flow: "scrolled-continuous", modes: ["vertical-rl", "horizontal-tb"]))
        view.loadedScrollGroup = 0..<2
        let spy = ScrollEventSpy()
        view.delegate = spy
        let markers: [[String: Any]] = [["label": "10", "page": 0], ["label": "11", "page": 1]]
        let reports: [(Int, Int, Double, [[String: Any]])] = [
            (0, 0, 0.1, markers), (0, 0, 0.1, markers), (0, 1, 0.2, markers),
            (1, 0, 0.0, []), (1, 0, 0.0, []),
        ]
        for (index, page, progression, markers) in reports {
            view.handleScriptMessage([
                "type": "pageChanged", "spineIndex": index, "page": page, "pageCount": 8,
                "progression": progression, "pagesPerScreen": 1,
                "mode": index == 0 ? "vrl" : "htb", "printPageMarkers": markers,
                "token": view.currentDocumentToken,
            ])
        }
        XCTAssertEqual(spy.events, ["print:10", "move:0:0:8:0.1", "move:0:0:8:0.1",
                                    "print:11", "move:0:1:8:0.2", "print:nil",
                                    "move:1:0:8:0.0", "move:1:0:8:0.0"])
        XCTAssertEqual(view.setupResultApplyCount, 2, "章ごとに 1 回だけ適用する")
        XCTAssertEqual(view.scrolledWheel.mode, "htb")
        XCTAssertFalse(view.isPageCoverPrefetchScheduled)
    }

    /// markers の無い pageChanged(ページ表示)は従来どおり applySetupResult を呼ばない。
    func testPageChangedWithoutMarkersNeverAppliesSetupResult() {
        let view = EPUBReaderView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        view.handleScriptMessage(["type": "pageChanged", "page": 1, "pageCount": 4, "pagesPerScreen": 2])
        XCTAssertEqual(view.setupResultApplyCount, 0)
        XCTAssertEqual(view.pageInItem, 1)
        XCTAssertEqual(view.pagesPerScreen, 2)
    }

    // MARK: - (3) 控えを使わない場面では撮影 Task を起こさない

    func testPageCoverPrefetchIsNotScheduledWhenCoverIsUnused() throws {
        let view = EPUBReaderView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        view.accessibilityReduceMotionOverride = false
        let cover = EPUBReaderView.PrefetchedPageCover(
            image: NSImage(size: view.bounds.size), rect: view.bounds, backingScale: 2,
            spineIndex: 0, pageInItem: 0, size: view.bounds.size, fontScale: view.settings.fontScale)

        // 演出ありの送り: Task を起こさず、古い控えはその場で捨てる
        view.settings.pageTurnStyle = .slide
        view.setPrefetchedPageCoverForTesting(cover)
        view.schedulePageCoverPrefetch()
        XCTAssertFalse(view.isPageCoverPrefetchScheduled)
        XCTAssertNil(view.pageCover.prefetchedPageCover)

        // 演出なしの送り(ページ表示): 従来どおり予約する
        view.settings.pageTurnStyle = .none
        view.schedulePageCoverPrefetch()
        XCTAssertTrue(view.isPageCoverPrefetchScheduled)
        view.dropPrefetchedPageCover()
        XCTAssertFalse(view.isPageCoverPrefetchScheduled)

        // スクロール表示の本: 演出なしでも控えは使わないので予約しない
        let scrolled = try scrollPublication(flow: "scrolled-doc")
        view.preparePublication(scrolled)
        XCTAssertTrue(EPUBScreenMetrics.isScrolled(view.effectiveFlow))
        view.setPrefetchedPageCoverForTesting(cover)
        view.schedulePageCoverPrefetch()
        XCTAssertFalse(view.isPageCoverPrefetchScheduled)
        XCTAssertNil(view.pageCover.prefetchedPageCover)
    }
}

/// 印刷ページと移動の通知を到着順に記録する
@MainActor
private final class ScrollEventSpy: EPUBReaderViewDelegate {
    var events: [String] = []
    func readerView(_ view: EPUBReaderView, didChangePrintPage label: String?) {
        events.append("print:\(label ?? "nil")")
    }
    func readerView(_ view: EPUBReaderView, didMoveTo locator: EPUBLocator,
                    pageInItem: Int, pageCountInItem: Int) {
        events.append("move:\(locator.spineIndex):\(pageInItem):\(pageCountInItem):\(locator.progression)")
    }
}
