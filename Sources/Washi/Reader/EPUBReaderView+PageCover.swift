import AppKit
import WebKit

/// EPUBReaderView の先撮りカバー: spine 遷移中に地色を見せないための
/// 現在ページの控え(撮影・取り置き・貼付・破棄)と、その撮り直し契機。
extension EPUBReaderView {
    /// spine 遷移中に被せる、現在ページの控えのスナップショット。
    ///
    /// 新しい文書のコミットから表示が戻るまで WebView は透明になる。演出なしの
    /// 送りでは、表示が落ち着いたときに撮っておいたこの絵を被せて地色を見せない。
    struct PrefetchedPageCover {
        let image: NSImage
        /// 撮ったときの webView.frame。貼るときもこの矩形に置く
        let rect: NSRect
        let backingScale: CGFloat
        let spineIndex: Int
        let pageInItem: Int
        let size: NSSize
        let fontScale: Double

        /// 撮ったときと表示条件が一致するか(一致しなければ使わない)
        func matches(spineIndex: Int, pageInItem: Int, size: NSSize,
                     fontScale: Double, backingScale: CGFloat) -> Bool {
            self.spineIndex == spineIndex && self.pageInItem == pageInItem
                && matchesDisplay(size: size, fontScale: fontScale,
                                  backingScale: backingScale)
        }

        /// 大きさ・文字の倍率・画面の倍率が撮ったときと一致するか(項目とページは問わない)
        func matchesDisplay(size: NSSize, fontScale: Double,
                            backingScale: CGFloat) -> Bool {
            self.size == size && self.fontScale == fontScale
                && self.backingScale == backingScale
        }
    }

    // MARK: - 先撮りカバー

    /// 送りが止まってから撮るまでの待ち。連続した送りの間は取り消されて撮らない。
    private static let pageCoverPrefetchDelay = Duration.milliseconds(80)
    /// 控えが無いときは次のフレームで撮る(次の境界に間に合わせる)
    private static let pageCoverFirstPrefetchDelay = Duration.milliseconds(16)
    /// カバーの掲示中に撮り直す回数の上限
    private static let pageCoverPrefetchRetryLimit = 8

    /// 演出なしで送る設定か(ページめくり none、または視差効果を減らす設定)
    private var turnsPagesWithoutAnimation: Bool {
        settings.pageTurnStyle == .none || accessibilityShouldReduceMotion
    }

    /// 控えを使う条件: 演出なしの送り(または視差効果を減らす設定)で、
    /// ページ単位の表示であること。演出ありの送りは既存の演出カバーが隠す
    private var usesPrefetchedPageCover: Bool {
        turnsPagesWithoutAnimation && !EPUBScreenMetrics.isScrolled(effectiveFlow)
    }

    /// 項目の最初か最後の画面にいるか(送りで spine 境界を越えうる)
    private var isAtItemBoundaryScreen: Bool {
        pageInItem == 0 || pageInItem + max(1, pagesPerScreen) >= pageCountInItem
    }

    /// ウィンドウが実際に画面に出ているか(最小化・遮蔽を除く)
    private var isWindowOnScreen: Bool {
        guard let window, allowsVisibleRenderingWork else { return false }
        if let isWindowOnScreenOverride { return isWindowOnScreenOverride }
        return !window.isMiniaturized && window.occlusionState.contains(.visible)
    }

    private var currentBackingScale: CGFloat { window?.backingScaleFactor ?? 2 }

    func schedulePageCoverPrefetch(after delay: Duration? = nil) {
        pageCoverPrefetchTask?.cancel()
        if delay == nil { pageCoverPrefetchRetries = 0 }
        let wait = delay ?? (prefetchedPageCover == nil
            ? Self.pageCoverFirstPrefetchDelay : Self.pageCoverPrefetchDelay)
        pageCoverPrefetchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: wait)
            guard let self, !Task.isCancelled else { return }
            await self.capturePageCover()
        }
    }

    /// 描画フレームを待ってから撮影を予約する。待ちも pageCoverPrefetchTask に載せるので、
    /// 後の予約・破棄・armSpineCoverForTransition が取り消す。撮らない場面では待たない。
    func schedulePageCoverPrefetchAfterFrames() {
        pageCoverPrefetchTask?.cancel()
        pageCoverPrefetchTask = nil
        guard let webView, usesPrefetchedPageCover, isAtItemBoundaryScreen,
              isWindowOnScreen, !isLoadingSpineItem, !isSettingUp else { return }
        let wait = animationFrameWait
        let timeout = animationFrameWaitTimeout
        pageCoverPrefetchTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled else { return }
            _ = await TimeoutRace.run({ await wait(webView) }, timeout: timeout)
            guard let self, !Task.isCancelled, webView === self.webView else { return }
            self.schedulePageCoverPrefetch()
        }
    }

    /// 古い見た目の控えはその場で捨て、変更が描画されてから撮り直す。
    /// washi ワールドの JS は送った順に実行されるので、見た目の変更を送った直後に
    /// 呼び、描画フレーム待ちを後から送る。変更が続いたら前の待ちは取り消され、
    /// 最後に 1 回だけ撮る。
    func retakePageCoverAfterRestyle() {
        dropPrefetchedPageCover()
        schedulePageCoverPrefetchAfterFrames()
    }

    /// 控えと撮影の予約を捨てる。撮影中の結果も取り消しで捨て、取り置いた控えは残す。
    func dropPrefetchedPageCover() {
        pageCoverPrefetchTask?.cancel()
        pageCoverPrefetchTask = nil
        pageCoverPrefetchRetries = 0
        prefetchedPageCover = nil
    }

    /// 控えと撮影の予約に加え、遷移のために取り置いた控えも捨てる。
    func discardPageCovers() {
        dropPrefetchedPageCover()
        armedSpineCover = nil
    }

    /// 現在の表示を等倍で 1 枚撮る。合成はしない(メインスレッドを止めないため)。
    private func capturePageCover() async {
        // 使わない場面では持たない(古い控えも捨てる)
        guard usesPrefetchedPageCover, isAtItemBoundaryScreen, isWindowOnScreen else {
            prefetchedPageCover = nil
            return
        }
        guard let webView, publication != nil,
              !isLoadingSpineItem, !isSettingUp else { return }
        // カバーの掲示中はカバー自身を撮ってしまうので、少し後に撮り直す
        guard turnOverlays.isEmpty else {
            guard pageCoverPrefetchRetries < Self.pageCoverPrefetchRetryLimit else { return }
            pageCoverPrefetchRetries += 1
            schedulePageCoverPrefetch(after: Self.pageCoverPrefetchDelay)
            return
        }
        pageCoverPrefetchRetries = 0
        let spineIndex = currentSpineIndex
        let page = pageInItem
        let size = bounds.size
        let rect = webView.frame
        let backingScale = currentBackingScale
        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = false
        guard let image = try? await webView.takeSnapshot(configuration: config)
        else { return }
        // 撮影中にページや表示条件が変わっていたら捨てる
        guard !Task.isCancelled, webView === self.webView,
              !isLoadingSpineItem, turnOverlays.isEmpty,
              spineIndex == currentSpineIndex, page == pageInItem,
              size == bounds.size, rect == webView.frame else { return }
        prefetchedPageCover = PrefetchedPageCover(
            image: image, rect: rect, backingScale: backingScale,
            spineIndex: spineIndex, pageInItem: page,
            size: size, fontScale: settings.fontScale)
    }

    /// loadSpineItem が currentSpineIndex を書き換える前に呼ぶ。控えが離れるページの
    /// ものなら取り置き、そうでなければカバー無しで読み込む。
    /// コミット待ちで前のページが見えている間は、取り置いた控えを引き継ぐ(Washi-3b1)
    func armSpineCoverForTransition() {
        let held = prefetchedPageCover
        prefetchedPageCover = nil
        pageCoverPrefetchTask?.cancel()
        if isAwaitingCommit, let webView, webView.url != nil, webView.alphaValue > 0 {
            // currentSpineIndex・pageInItem は前の読み込みが書き換えたので照合しない。
            // effectiveFlow も読み込み中の項目を指し、見えているページがページ単位でも
            // スクロール表示になりうるので、ここでは usesPrefetchedPageCover を使わない。
            // 見えているページの flow は取り置き時に確認済みで、表示条件だけ照合し直す
            guard let armed = armedSpineCover, turnsPagesWithoutAnimation,
                  armed.matchesDisplay(size: bounds.size, fontScale: settings.fontScale,
                                       backingScale: currentBackingScale) else {
                armedSpineCover = nil
                return
            }
            return
        }
        guard let held, usesPrefetchedPageCover,
              held.matches(spineIndex: currentSpineIndex, pageInItem: pageInItem,
                           size: bounds.size, fontScale: settings.fontScale,
                           backingScale: currentBackingScale) else {
            armedSpineCover = nil
            return
        }
        armedSpineCover = held
    }

    /// 取り置いた控えをカバーとして撮影時の矩形に貼る。既存のカバーの回収経路
    /// (pendingSpineTurn・時間切れ・runSetup)に乗せる
    func installSpineCover(_ held: PrefetchedPageCover) {
        guard let webView, allowsVisibleRenderingWork else { return }
        let cover = NSImageView(image: held.image)
        cover.imageScaling = .scaleAxesIndependently
        cover.frame = held.rect
        addSubview(cover, positioned: .above, relativeTo: webView)
        turnOverlays.append(cover)
        updateFurnitureSuppression()
        clearPendingSpineTurn()
        pendingSpineTurn = PendingSpineTurn(
            oldPage: held.image, cover: cover, forward: true, animated: false)
        // 重い画像ページの読み込みにも耐えるよう、時間切れは長めにする
        scheduleSpineTurnTimeout(for: cover, after: .seconds(8))
    }

    /// 画面の倍率が変わったら、章の切り替わりに重ねる控えを撮り直す。
    ///
    /// Retakes the snapshot laid over chapter transitions when the backing scale changes.
    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let cover = prefetchedPageCover,
              cover.backingScale != currentBackingScale else { return }
        retakePageCoverAfterRestyle()
    }

    /// 最小化・遮蔽されたら控えを捨てる(数十 MB になりうる)。画面に戻ったら撮り直す。
    @objc func windowVisibilityDidChange(_ notification: Notification) {
        guard isWindowOnScreen else { dropPrefetchedPageCover(); return }
        // 見えたままの通知が重なっても、使える控えを撮り直さない
        guard prefetchedPageCover == nil else { return }
        schedulePageCoverPrefetchAfterFrames()
    }
}
