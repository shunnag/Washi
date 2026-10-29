import AppKit
import XCTest
@testable import Washi
@testable import WashiCore

/// 調査候補の再測定。出力先と読み取り専用コーパスを明示した場合だけ実行する。
final class PerformanceCandidateHarnessTests: XCTestCase {
    func testCoreTimingAndImageParity() throws {
        let env = ProcessInfo.processInfo.environment
        guard let output = env["WASHI_CORE_BENCH_OUT"], let corpus = env["WASHI_CORPUS_DIR"] else {
            throw XCTSkip("WASHI_CORE_BENCH_OUT と WASHI_CORPUS_DIR が必要です")
        }
        let root = URL(fileURLWithPath: corpus)
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
        let urls = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "epub" }
            .sorted { $0.path < $1.path }
        var records: [[String: Any]] = []
        var samples: [Double] = []
        for url in urls {
            let name = String(url.path.dropFirst(root.path.count + 1))
            var times: [Double] = []
            var publication: EPUBPublication!
            for _ in 0..<5 {
                let start = ContinuousClock.now
                publication = try EPUBPublication(url: url)
                times.append(Self.seconds(ContinuousClock.now - start))
            }
            var flags: [Bool] = []
            var itemSeconds: [Double] = []
            for entry in publication.readingOrder {
                let start = ContinuousClock.now
                let image = publication.isSingleImageItem(atSpineIndex: entry.spineIndex)
                let elapsed = Self.seconds(ContinuousClock.now - start)
                if publication.package.effectiveLayout(for: entry.itemRef) != .prePaginated {
                    samples.append(elapsed)
                }
                itemSeconds.append(elapsed)
                let dom = try publication.fixedLayoutInfo(forSpineIndex: entry.spineIndex).simpleImagePath != nil
                XCTAssertEqual(image, dom, "\(name) #\(entry.spineIndex)")
                flags.append(image)
            }
            let record: [String: Any] = ["book": name, "openSeconds": times,
                "paths": publication.readingOrder.map(\.resolvedContainerPath), "images": flags,
                "itemSeconds": itemSeconds,
                "toc": publication.navigation.flattenedTOC.map {
                    ["title": $0.title, "href": $0.href ?? "", "depth": $0.depth,
                     "spineIndex": $0.href.flatMap { publication.spineIndex(forHref: $0) } ?? -1] as [String: Any]
                }]
            records.append(record)
        }
        samples.sort()
        let result: [String: Any] = ["books": records, "imageSeconds": samples]
        try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]).write(to: URL(fileURLWithPath: output))
        print("[Washi core bench] books=\(records.count) items=\(samples.count) total=\(samples.reduce(0,+)) p99=\(samples[Int(Double(samples.count-1)*0.99)]) max=\(samples.last ?? 0)")
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
