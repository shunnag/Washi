import Foundation

/// async 操作を期限付きで待つ単発の競走。表示中のリーダーの描画待ち
/// (rAF・控えの撮影)が使う。
///
/// EPUBOffscreenWaiting(Offscreen)も「先着だけを採る」門を持つが、形が
/// 違う。あちらは WebKit の完了コールバックを MainActor 隔離の門で受け、
/// キャンセルは Task { @MainActor } を経て閉じる。こちらは async 操作を
/// 子 Task で走らせ、NSLock の RaceGate を非隔離の onCancel から同期的に
/// 閉じる。この取り消しのタイミングの差は意図したもので、2 つを統合しない。
@MainActor
enum TimeoutRace {
    /// `operation` の完了か `timeout` の早い方まで待つ。完了したら true。
    /// 呼び出し側のタスクが取り消されたときも、その時点で戻る。
    ///
    /// `requestAnimationFrame` は合成されていないウィンドウ(最小化・別 Space・
    /// 遮蔽)では進まないので、打ち切らないと表示が戻らなくなる。
    static func run(_ operation: @escaping @MainActor () async -> Void,
                    timeout: Duration) async -> Bool {
        let gate = RaceGate()
        let work = Task { @MainActor in
            await operation()
            gate.finish(completed: true)
        }
        let timer = Task {
            try? await Task.sleep(for: timeout)
            gate.finish(completed: false)
        }
        let completed = await withTaskCancellationHandler {
            await withCheckedContinuation { gate.install($0) }
        } onCancel: {
            gate.finish(completed: false)
        }
        timer.cancel()
        work.cancel()
        return completed
    }

    /// race の結果を一度だけ返すための門。
    private final class RaceGate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?
        private var result: Bool?

        func install(_ continuation: CheckedContinuation<Bool, Never>) {
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(returning: result)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }

        func finish(completed: Bool) {
            lock.lock()
            guard result == nil else { lock.unlock(); return }
            result = completed
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(returning: completed)
        }
    }
}
