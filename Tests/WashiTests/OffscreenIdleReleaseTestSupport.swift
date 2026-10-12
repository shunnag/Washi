import Foundation
@testable import Washi

/// cooViewer-oxr.68: 実時間を進めず、期限切れとキャンセル済み callback の
/// 競合を MainActor 上で決定的に再現するテスト用 scheduler。
@MainActor
final class ManualOffscreenIdleScheduler {
    @MainActor
    final class Entry {
        let delay: Duration
        /// 予約時の仮想時刻 + delay(advance(by:) の発火判定用)
        let deadline: Duration
        let action: @MainActor @Sendable () -> Void
        var isCancelled = false
        var isFired = false

        init(delay: Duration, deadline: Duration,
             action: @escaping @MainActor @Sendable () -> Void) {
            self.delay = delay
            self.deadline = deadline
            self.action = action
        }
    }

    /// 仮想時刻(advance(by:) で進む)
    private(set) var elapsed: Duration = .zero
    private(set) var entries: [Entry] = []
    var firesNextEntrySynchronously = false

    var scheduler: EPUBOffscreenIdleReleaseTimer.Scheduler {
        { [weak self] delay, action in
            guard let self else { return {} }
            let entry = Entry(delay: delay, deadline: elapsed + delay, action: action)
            entries.append(entry)
            if firesNextEntrySynchronously {
                firesNextEntrySynchronously = false
                entry.isFired = true
                entry.action()
            }
            return { entry.isCancelled = true }
        }
    }

    var lastActiveEntry: Entry? {
        entries.last { !$0.isCancelled && !$0.isFired }
    }

    /// 仮想時刻を進め、経過した有効な期限だけを発火する。
    func advance(by duration: Duration) {
        elapsed += duration
        for entry in entries where entry.deadline <= elapsed {
            fire(entry)
        }
    }

    func fire(_ entry: Entry, includingCancelled: Bool = false) {
        guard !entry.isFired,
              includingCancelled || !entry.isCancelled else { return }
        entry.isFired = true
        entry.action()
    }
}

/// Washi-z74.13: setup の期限を予約する瞬間(読み込み完了後・JS 実行前)に、
/// `triggerAtScheduleCount` 回目だけ `onTrigger` を呼び(census の invalidate や
/// ビューの非表示など、実測を途中で止める操作)、期限自体は実時間の scheduler
/// へ委ねる(WebView が応答しなくても期限で抜けるので、テストが止まらない)。
/// 回数は読み込んだ項目数に一致するので、k 項目目で止める中断を決定的に起こせる。
@MainActor
final class TriggeringSetupScheduler {
    var triggerAtScheduleCount = 1
    var onTrigger: @MainActor () -> Void = {}
    private(set) var scheduleCount = 0

    var scheduler: EPUBOffscreenIdleReleaseTimer.Scheduler {
        { [weak self] delay, action in
            guard let self else { return {} }
            scheduleCount += 1
            if scheduleCount == triggerAtScheduleCount {
                onTrigger()
            }
            return EPUBOffscreenIdleReleaseTimer.continuousScheduler(delay, action)
        }
    }
}
