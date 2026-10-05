import AppKit
import WebKit

extension EPUBReaderView {
    struct ScrolledWheelState {
        var mode: String?
        var pendingDeltas: [Double] = []
        var isScheduled = false
        var isInFlight = false
        var generation: UInt = 0
        var horizontal: Bool?
        var hasMouseGesture = false
        var lastTime: TimeInterval = 0
        var fractionalRemainder: CGFloat = 0
        var direction: CGFloat = 0

        mutating func reset(mode: String? = nil) {
            self = ScrolledWheelState(mode: mode, generation: generation &+ 1)
        }

        mutating func axis(for event: NSEvent) -> Bool? {
            let hasPhase = !event.phase.isEmpty || !event.momentumPhase.isEmpty
            let startsGesture = event.phase.contains(.began) || event.phase.contains(.mayBegin)
                || (!hasPhase && event.timestamp - lastTime > 0.25)
            if startsGesture {
                horizontal = nil
                hasMouseGesture = !hasPhase
                fractionalRemainder = 0
                direction = 0
            }
            if hasPhase { hasMouseGesture = false }
            lastTime = event.timestamp
            let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
            guard dx != 0 || dy != 0 else { return horizontal }
            // 通常のマウスは静穏で区切る。phase もその区切りもないイベントは
            // ジェスチャの軸を持たず、各イベントの優勢軸を使う。
            if !hasPhase && !hasMouseGesture {
                horizontal = nil
                return abs(dx) > abs(dy)
            }
            if horizontal == nil { horizontal = abs(dx) > abs(dy) }
            return horizontal
        }

        mutating func wholePixels(from pixels: CGFloat) -> Double {
            let nextDirection: CGFloat = pixels > 0 ? 1 : -1
            if nextDirection != direction { fractionalRemainder = 0 }
            direction = nextDirection
            // WebKit の整数位置を読み戻しても失わないよう、1px 未満を native に残す。
            let total = pixels + fractionalRemainder
            let whole = total.rounded(.towardZero)
            fractionalRemainder = total - whole
            return Double(whole)
        }
    }

    /// 縦書きの縦操作と連続表示の横操作を受ける。章単位の横操作は WebKit に
    /// 委ね、連続表示は外側と iframe が別々に動かないよう同じ経路で送る。
    func scrollScrolledFlowByWheel(_ event: NSEvent) -> Bool {
        guard scrolledWheel.mode == "vrl" || scrolledWheel.mode == "vlr" else { return false }
        guard !spineLoad.isLoadingSpineItem else { return true }
        let horizontal = scrolledWheel.axis(for: event)
        if effectiveFlow == .scrolledDoc, horizontal != false { return false }
        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY
        // AppKit は DOM wheel と逆符号。下向きは書字方向へ進む。
        let delta = horizontal == true ? dx * (scrolledWheel.mode == "vrl" ? 1 : -1) : -dy
        let pixels = delta * (event.hasPreciseScrollingDeltas ? 1 : WheelInput.pixelsPerLine)
        guard pixels.isFinite, pixels != 0 else { return true }
        let whole = scrolledWheel.wholePixels(from: pixels)
        guard whole != 0 else { return true }
        // 向きが変わった順序は残す。端で「戻る→進む」を相殺すると移動を失う。
        if let last = scrolledWheel.pendingDeltas.last, (last > 0) == (whole > 0) {
            scrolledWheel.pendingDeltas[scrolledWheel.pendingDeltas.count - 1] += whole
        } else {
            scrolledWheel.pendingDeltas.append(whole)
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
