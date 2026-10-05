import AppKit
import WebKit

extension EPUBReaderView {
    struct ScrolledWheelState {
        var mode: String?
        var pendingDeltas: [Double] = []
        var isScheduled = false
        var isInFlight = false
        var generation: UInt = 0

        mutating func reset(mode: String? = nil) {
            self = ScrolledWheelState(mode: mode, generation: generation &+ 1)
        }
    }

    /// 水平軸のスクロールだけを受ける。イベントを WebKit にも渡すと、外側と
    /// iframe が別々に動き、次の逆向きのジェスチャで位置が跳ぶ。
    func scrollScrolledFlowByWheel(_ event: NSEvent) -> Bool {
        guard scrolledWheel.mode == "vrl" || scrolledWheel.mode == "vlr" else { return false }
        guard !spineLoad.isLoadingSpineItem else { return true }
        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY
        // AppKit は DOM wheel と逆符号。軸は毎回選び、下向きは書字方向へ進む。
        let delta = abs(dx) > abs(dy) ? dx * (scrolledWheel.mode == "vrl" ? 1 : -1) : -dy
        // continuousScrollScript の deltaMode === 1 と同じ 1 行 = 20px。
        let pixels = delta * (event.hasPreciseScrollingDeltas ? 1 : 20)
        guard pixels.isFinite, pixels != 0 else { return true }
        // 向きが変わった順序は残す。端で「戻る→進む」を相殺すると移動を失う。
        if let last = scrolledWheel.pendingDeltas.last, (last > 0) == (pixels > 0) {
            scrolledWheel.pendingDeltas[scrolledWheel.pendingDeltas.count - 1] += Double(pixels)
        } else {
            scrolledWheel.pendingDeltas.append(Double(pixels))
        }
        scheduleScrolledWheel()
        return true
    }

    private func scheduleScrolledWheel() {
        guard !scrolledWheel.pendingDeltas.isEmpty,
              !scrolledWheel.isScheduled, !scrolledWheel.isInFlight else { return }
        scrolledWheel.isScheduled = true
        let generation = scrolledWheel.generation
        // 同じターンのイベントは加算だけにし、JS 応答待ちの間も一つにまとめる。
        DispatchQueue.main.async { [weak self] in
            guard let self, self.scrolledWheel.generation == generation else { return }
            self.scrolledWheel.isScheduled = false
            self.flushScrolledWheel()
        }
    }

    private func flushScrolledWheel() {
        let deltas = scrolledWheel.pendingDeltas
        scrolledWheel.pendingDeltas = []
        guard !deltas.isEmpty, !spineLoad.isLoadingSpineItem, let webView else { return }
        scrolledWheel.isInFlight = true
        let generation = scrolledWheel.generation
        // 送信済みの要求も文書の印で拒否し、読み込み直後の別文書へ遅配しない。
        webView.callAsyncJavaScript(
            "return __washi.scrollByWheelDelta(delta, token);",
            arguments: ["delta": deltas, "token": currentDocumentToken],
            in: nil, in: WashiContentWorld.world
        ) { [weak self, weak webView] _ in
            guard let self, webView === self.webView,
                  self.scrolledWheel.generation == generation else { return }
            self.scrolledWheel.isInFlight = false
            self.scheduleScrolledWheel()
        }
    }
}
