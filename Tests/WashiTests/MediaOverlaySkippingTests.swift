import AppKit
import WebKit
import XCTest
@testable import Washi
@testable import WashiCore

@MainActor
private final class MediaOverlayNavigationReentryDelegate: EPUBReaderViewDelegate {
    var redirect: EPUBLocator?
    var didRedirect = false

    func readerView(_ view: EPUBReaderView,
                    selectionDidChange selection: EPUBTextSelection?) {
        guard selection == nil, !didRedirect, let redirect else { return }
        didRedirect = true
        view.go(to: redirect)
    }
}

private final class FakeMediaOverlayAudioPlayer: MediaOverlayAudioPlayer {
    var currentTime: TimeInterval = 0
    let duration: TimeInterval = 2
    private(set) var isPlaying = false
    var enableRate = false
    var rate: Float = 1
    private(set) var playCount = 0

    func prepareToPlay() -> Bool { true }
    func play() -> Bool {
        playCount += 1
        isPlaying = true
        return true
    }
    func pause() { isPlaying = false }
    func stop() { isPlaying = false }
}

@MainActor
final class MediaOverlaySkippingTests: XCTestCase {
    private func silentPCM(seconds: Int = 2, sampleRate: Int = 8_000) -> Data {
        let sampleBytes = seconds * sampleRate * 2
        var data = Data()
        func ascii(_ string: String) { data.append(contentsOf: string.utf8) }
        func littleEndian<T: FixedWidthInteger>(_ value: T) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        ascii("RIFF")
        littleEndian(UInt32(36 + sampleBytes))
        ascii("WAVEfmt ")
        littleEndian(UInt32(16))
        littleEndian(UInt16(1))
        littleEndian(UInt16(1))
        littleEndian(UInt32(sampleRate))
        littleEndian(UInt32(sampleRate * 2))
        littleEndian(UInt16(2))
        littleEndian(UInt16(16))
        ascii("data")
        littleEndian(UInt32(sampleBytes))
        data.append(Data(count: sampleBytes))
        return data
    }

    private func book(skippedCount: Int, trailingBody: Bool = false) throws -> EPUBPublication {
        let count = skippedCount + (trailingBody ? 1 : 0)
        let entries = EPUBFixtures.silentMediaOverlayEntries(parCount: count).map { entry in
            guard entry.name.hasSuffix(".smil") else { return entry }
            var smil = String(decoding: entry.data, as: UTF8.self)
                .replacingOccurrences(of: "<smil ", with:
                    "<smil xmlns:epub=\"http://www.idpf.org/2007/ops\" ")
                .replacingOccurrences(of: "<par ", with: "<par epub:type=\"pagebreak\" ")
            if trailingBody {
                smil = smil.replacingOccurrences(
                    of: "<par epub:type=\"pagebreak\" id=\"p\(skippedCount)\"",
                    with: "<par id=\"p\(skippedCount)\"")
            }
            return (name: entry.name, data: Data(smil.utf8))
        }
        return try EPUBPublication(data: ZipBuilder.build(entries, method: 8),
                                   displayURL: URL(fileURLWithPath: "/tmp/washi-skipped-overlay.epub"))
    }

    private func reader(for book: EPUBPublication) -> EPUBReaderView {
        let reader = EPUBReaderView(frame: .zero)
        reader.load(publication: book)
        reader.settings.mediaOverlaySkippedTypes = ["pagebreak"]
        return reader
    }

    private func audioBookWithSkippedMiddleClip() throws -> EPUBPublication {
        var entries = EPUBFixtures.silentMediaOverlayEntries(parCount: 3)
        let smilIndex = try XCTUnwrap(entries.firstIndex { $0.name.hasSuffix(".smil") })
        let smil = """
        <smil xmlns="http://www.w3.org/ns/SMIL"
              xmlns:epub="http://www.idpf.org/2007/ops">
          <body><seq>
            <par><text src="c.xhtml#s0"/>
              <audio src="narration.wav" clipBegin="0s" clipEnd="0.15s"/></par>
            <par epub:type="pagebreak"><text src="c.xhtml#s1"/>
              <audio src="narration.wav" clipBegin="0.15s" clipEnd="1.25s"/></par>
            <par><text src="c.xhtml#s2"/>
              <audio src="narration.wav" clipBegin="1.25s" clipEnd="1.8s"/></par>
          </seq></body>
        </smil>
        """
        entries[smilIndex].data = Data(smil.utf8)
        entries.append(("OEBPS/text/narration.wav", silentPCM()))
        return try EPUBPublication(
            data: ZipBuilder.build(entries, method: 8),
            displayURL: URL(fileURLWithPath: "/tmp/washi-skipped-audio.epub"))
    }

    private func bookWithSkippedOverlays(_ skippedOverlayCount: Int,
                                         emptyOverlayAt: Int? = nil) throws
        -> EPUBPublication {
        var manifest = ""
        var spine = ""
        var entries: [(name: String, data: Data)] = [
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", Data(EPUBFixtures.containerXML.utf8)),
        ]
        for index in 0...skippedOverlayCount {
            manifest += """
              <item id="c\(index)" href="text/c\(index).xhtml" media-type="application/xhtml+xml" media-overlay="m\(index)"/>
              <item id="m\(index)" href="text/m\(index).smil" media-type="application/smil+xml"/>
            """
            spine += "<itemref idref=\"c\(index)\"/>"
            entries.append(("OEBPS/text/c\(index).xhtml", Data(
                "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><p id=\"p\">\(index)</p></body></html>".utf8)))
            let contents: String
            if emptyOverlayAt == index {
                contents = "<smil xmlns=\"http://www.w3.org/ns/SMIL\"><body/></smil>"
            } else {
                let type = index < skippedOverlayCount
                    ? " epub:type=\"pagebreak\"" : ""
                contents = "<smil xmlns=\"http://www.w3.org/ns/SMIL\" xmlns:epub=\"http://www.idpf.org/2007/ops\"><body><par\(type)><text src=\"c\(index).xhtml#p\"/></par></body></smil>"
            }
            entries.append(("OEBPS/text/m\(index).smil", Data(contents.utf8)))
        }
        let opf = """
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="uid">urn:uuid:many-overlays</dc:identifier>
            <dc:title>Many overlays</dc:title><dc:language>en</dc:language>
            <meta property="dcterms:modified">2026-09-10T00:00:00Z</meta>
          </metadata>
          <manifest>\(manifest)</manifest><spine>\(spine)</spine>
        </package>
        """
        entries.append(("OEBPS/package.opf", Data(opf.utf8)))
        return try EPUBPublication(
            data: ZipBuilder.build(entries, method: 8),
            displayURL: URL(fileURLWithPath: "/tmp/washi-many-skipped-overlays.epub"))
    }

    func testAllSkippedOverlayFinishesInsteadOfBecomingPlayingAgain() throws {
        let reader = reader(for: try book(skippedCount: 3))
        defer { reader.stopMediaOverlay() }
        reader.playMediaOverlay()
        XCTAssertFalse(reader.isPlayingMediaOverlay)
        XCTAssertNil(reader.mediaOverlayPosition)
    }

    func testLongSkippedRunUsesBoundedStack() throws {
        let count = 20_000
        let reader = reader(for: try book(skippedCount: count, trailingBody: true))
        defer { reader.stopMediaOverlay() }
        reader.playMediaOverlay()
        XCTAssertEqual(reader.mediaOverlayPosition?.parIndex, count)
        XCTAssertTrue(reader.isPlayingMediaOverlay)
    }

    func testContiguousAudioStillSkipsMatchingClip() throws {
        let book = try audioBookWithSkippedMiddleClip()
        let reader = reader(for: book)
        let player = FakeMediaOverlayAudioPlayer()
        let controller = MediaOverlayController(
            reader: reader, publication: book, activeClass: "x",
            makeAudioPlayer: { _ in player })
        reader.mediaOverlayController = controller
        controller.continuesToNextItem = false
        controller.skippedTypes = ["pagebreak"]
        controller.play(fromSpineIndex: 0)
        defer { controller.stop() }
        XCTAssertTrue(controller.isPlaying)
        XCTAssertEqual(controller.currentParIndex, 0)
        XCTAssertEqual(player.playCount, 1)
        player.currentTime = 0.15

        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline, controller.currentParIndex == 0 {
            RunLoop.main.run(mode: .default,
                             before: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(controller.currentParIndex, 2,
                       "A contiguous clip must pass through the skip filter")
        XCTAssertEqual(player.currentTime, 1.25, accuracy: 0.001)
        XCTAssertEqual(player.playCount, 2)
    }

    func testContiguousUnskippedClipKeepsCurrentPlayerRunning() throws {
        let book = try audioBookWithSkippedMiddleClip()
        let reader = EPUBReaderView(frame: .zero)
        reader.load(publication: book)
        let player = FakeMediaOverlayAudioPlayer()
        let controller = MediaOverlayController(
            reader: reader, publication: book, activeClass: "x",
            makeAudioPlayer: { _ in player })
        reader.mediaOverlayController = controller
        controller.continuesToNextItem = false
        controller.play(fromSpineIndex: 0)
        defer { controller.stop() }
        player.currentTime = 0.15

        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline, controller.currentParIndex == 0 {
            RunLoop.main.run(mode: .default,
                             before: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(controller.currentParIndex, 1)
        XCTAssertEqual(player.currentTime, 0.15, accuracy: 0.001)
        XCTAssertEqual(player.playCount, 1,
                       "A contiguous playable clip must not restart its audio")
    }

    func testNonFinitePlaybackRateFallsBackToNormalSpeed() throws {
        let book = try audioBookWithSkippedMiddleClip()
        let reader = EPUBReaderView(frame: .zero)
        reader.load(publication: book)
        let player = FakeMediaOverlayAudioPlayer()
        let controller = MediaOverlayController(
            reader: reader, publication: book, activeClass: "x",
            makeAudioPlayer: { _ in player })
        reader.mediaOverlayController = controller
        controller.playbackRate = .nan
        controller.play(fromSpineIndex: 0)
        defer { controller.stop() }
        XCTAssertEqual(player.rate, 1)
        controller.playbackRate = .infinity
        XCTAssertEqual(player.rate, 1)
    }

    func testSkippedRunAcrossManyOverlaysUsesBoundedStack() throws {
        let skippedCount = 5_000
        let reader = reader(for: try bookWithSkippedOverlays(skippedCount))
        defer { reader.stopMediaOverlay() }
        reader.playMediaOverlay()
        XCTAssertEqual(reader.mediaOverlayPosition?.spineIndex, skippedCount)
        XCTAssertEqual(reader.mediaOverlayPosition?.parIndex, 0)
        XCTAssertTrue(reader.isPlayingMediaOverlay)
    }

    func testEmptyOverlayDoesNotHideLaterPlayableOverlay() throws {
        let reader = reader(for: try bookWithSkippedOverlays(
            2, emptyOverlayAt: 1))
        defer { reader.stopMediaOverlay() }
        reader.playMediaOverlay()
        XCTAssertEqual(reader.mediaOverlayPosition?.spineIndex, 2)
        XCTAssertEqual(reader.mediaOverlayPosition?.parIndex, 0)
        XCTAssertTrue(reader.isPlayingMediaOverlay)
    }

    func testSharedOverlayStartsAtCurrentSpineDocument() throws {
        let book = try EPUBPublication(
            data: ZipBuilder.build(
                EPUBFixtures.multiDocumentMediaOverlayEntries(), method: 8),
            displayURL: URL(fileURLWithPath: "/tmp/washi-shared-overlay-start.epub"))
        let reader = EPUBReaderView(frame: .zero)
        reader.load(publication: book)
        reader.go(to: book.locator(forSpineIndex: 1, progression: 0))
        XCTAssertEqual(reader.currentSpineIndex, 1)
        reader.playMediaOverlay()
        defer { reader.stopMediaOverlay() }
        XCTAssertEqual(reader.currentSpineIndex, 1)
        XCTAssertEqual(reader.mediaOverlayPosition?.spineIndex, 1)
        XCTAssertEqual(reader.mediaOverlayPosition?.parIndex, 2)
    }

    func testSharedOverlayMissingCurrentDocumentDoesNotNavigateBackward() throws {
        let entries = EPUBFixtures.multiDocumentMediaOverlayEntries().map { entry in
            guard entry.name.hasSuffix(".smil") else { return entry }
            let smil = """
            <smil xmlns="http://www.w3.org/ns/SMIL"><body>
              <par><text src="a.xhtml#s0"/></par>
            </body></smil>
            """
            return (entry.name, Data(smil.utf8))
        }
        let book = try EPUBPublication(
            data: ZipBuilder.build(entries, method: 8),
            displayURL: URL(fileURLWithPath: "/tmp/washi-incomplete-shared-overlay.epub"))
        let reader = EPUBReaderView(frame: .zero)
        reader.load(publication: book)
        reader.go(to: book.locator(forSpineIndex: 1, progression: 0))
        reader.playMediaOverlay()
        XCTAssertEqual(reader.currentSpineIndex, 1)
        XCTAssertFalse(reader.isPlayingMediaOverlay)
        XCTAssertNil(reader.mediaOverlayPosition)
    }

    func testManualSpineNavigationIsNotUndoneByNextSharedOverlayPar() throws {
        let book = try EPUBPublication(
            data: ZipBuilder.build(
                EPUBFixtures.multiDocumentMediaOverlayEntries(), method: 8),
            displayURL: URL(fileURLWithPath: "/tmp/washi-shared-overlay-leave.epub"))
        let reader = EPUBReaderView(frame: .zero)
        reader.load(publication: book)
        let controller = MediaOverlayController(
            reader: reader, publication: book, activeClass: "x")
        reader.mediaOverlayController = controller
        controller.play(fromSpineIndex: 0)
        reader.go(to: book.locator(forSpineIndex: 1, progression: 0))

        let deadline = Date().addingTimeInterval(0.6)
        while Date() < deadline, controller.isPlaying {
            RunLoop.main.run(mode: .default,
                             before: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(reader.currentSpineIndex, 1)
        XCTAssertFalse(controller.isPlaying)
        XCTAssertNil(reader.mediaOverlayPosition)
    }

    func testReentrantNavigationAbortsAutomaticOverlayTransition() async throws {
        let book = try bookWithSkippedOverlays(1)
        let reader = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 480, height: 360))
        let window = NSWindow(
            contentRect: reader.frame.offsetBy(dx: -20_000, dy: -20_000),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = reader
        let delegate = MediaOverlayNavigationReentryDelegate()
        delegate.redirect = book.locator(forSpineIndex: 0, progression: 0)
        reader.delegate = delegate
        defer {
            reader.stopMediaOverlay()
            window.contentView = nil
            window.close()
        }

        reader.load(publication: book)
        let web = try XCTUnwrap(
            reader.subviews.first { $0 is WKWebView } as? WKWebView)
        for _ in 0..<300 where web.alphaValue == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        reader.handleScriptMessage([
            "type": "selection", "text": "x", "start": 0, "end": 1,
            "rects": [] as [[String: Any]],
        ])
        XCTAssertNotNil(reader.currentSelection)
        reader.playMediaOverlay()
        for _ in 0..<150 where !delegate.didRedirect {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertTrue(delegate.didRedirect)
        XCTAssertEqual(reader.currentSpineIndex, 0)
        XCTAssertFalse(reader.isPlayingMediaOverlay)
        XCTAssertNil(reader.mediaOverlayPosition)
    }

    func testSkippingRecognizesAllXMLWhitespace() {
        let par = MediaOverlay.Parallel(textHref: nil, audioHref: nil, clipBegin: 0,
                                       clipEnd: nil, epubType: "bodymatter\tpagebreak\nfootnote")
        XCTAssertTrue(MediaOverlayController.isSkipped(par, types: ["pagebreak"]))
    }

    func testSkippedSequenceAppliesToDescendantPars() throws {
        let smil = """
        <smil xmlns="http://www.w3.org/ns/SMIL" xmlns:epub="http://www.idpf.org/2007/ops">
          <body><seq epub:type="footnote"><par><text src="c.xhtml#note"/></par></seq>
            <par><text src="c.xhtml#body"/></par>
          </body>
        </smil>
        """
        let overlay = try SMILParser.parse(data: Data(smil.utf8), at: "c.smil")
        XCTAssertTrue(MediaOverlayController.isSkipped(overlay.parallels[0], types: ["footnote"]))
        XCTAssertFalse(MediaOverlayController.isSkipped(overlay.parallels[1], types: ["footnote"]))
    }
}
