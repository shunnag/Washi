import Foundation

/// cooViewer-oxr.47: WebContent 終了の再試行回数とバックオフを spine ごとに
/// 決定し、短時間のクラッシュループを有限にする。
struct WebContentReloadLimiter {
    enum Decision: Equatable {
        case reload(after: Duration)
        case suppress(reportFailure: Bool)
    }

    private struct Entry {
        var terminations: [Date] = []
        var didReportFailure = false
    }

    private var entries: [Int: Entry] = [:]
    private let window: TimeInterval
    private let delays: [Duration]

    init(window: TimeInterval = 60,
         delays: [Duration] = [.zero, .milliseconds(250), .seconds(1)]) {
        self.window = window
        self.delays = delays
    }

    mutating func register(spineIndex: Int, at now: Date = Date()) -> Decision {
        var entry = entries[spineIndex] ?? Entry()
        entry.terminations.removeAll {
            now.timeIntervalSince($0) >= window || now < $0
        }
        if entry.terminations.isEmpty {
            entry.didReportFailure = false
        }
        entry.terminations.append(now)

        let attempt = entry.terminations.count
        guard attempt <= delays.count else {
            let shouldReport = !entry.didReportFailure
            entry.didReportFailure = true
            entries[spineIndex] = entry
            return .suppress(reportFailure: shouldReport)
        }
        entries[spineIndex] = entry
        return .reload(after: delays[attempt - 1])
    }

    mutating func reset() {
        entries.removeAll()
    }
}
