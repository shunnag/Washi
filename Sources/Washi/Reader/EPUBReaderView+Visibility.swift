import AppKit

/// EPUBReaderView の可視性: ウインドウへの着脱と表示・非表示に伴う
/// オフスクリーン処理の停止と、表示復帰時の延期していた作業の再開。
extension EPUBReaderView {
    // 最小化・遮蔽とその解除を購読し、控えを捨て・撮り直す
    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        let center = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification,
                     NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification] {
            if let window { center.removeObserver(self, name: name, object: window) }
            if let newWindow {
                center.addObserver(self, selector: #selector(windowVisibilityDidChange(_:)),
                                   name: name, object: newWindow)
            }
        }
    }

    /// ウインドウから外れたとき(ウインドウを閉じる、ビューを取り除く)に、
    /// オフスクリーンの実測を停止し、不可視ウインドウと WebContent プロセスを
    /// 破棄する。ホストが cancelPageCensus を明示的に使わなくても、リソースが
    /// 漏れないようにする。再表示された場合は、次回の runSetup / layout で
    /// census が自動的に再開する。メディアオーバーレイは位置を保って
    /// 一時停止し、ホストから再開できる。
    ///
    /// When detached from a window (close, view removal), stops the offscreen
    /// measurement and tears down the invisible window and WebContent process.
    /// A safeguard so that even a host unaware of the explicit cancelPageCensus
    /// does not leak. If shown again, the next runSetup / layout naturally
    /// resumes the census. Media overlays pause, preserving their position
    /// so the host can resume playback.
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateNativeKeyMonitor()
        guard window == nil else {
            resumeDeferredVisibleWork()
            return
        }
        pendingVisibleLayout = webView != nil
        cancelPageCensus()
        censusEngine?.invalidate()
        censusEngine = nil
        thumbnailRenderer?.invalidate()
        thumbnailRenderer = nil
        // 遅れて届く再生開始の JS 応答も無効化し、非表示中の再生復活を防ぐ。
        pauseMediaOverlay()
        discardPageCovers()
    }

    public override func viewDidHide() {
        super.viewDidHide()
        // cooViewer-oxr.54: 進行中の計測も隠れたビューのために継続しない。
        pendingVisibleLayout = webView != nil
        repaginateWork?.cancel()
        repaginateWork = nil
        pendingRepaginate = false
        cancelPageCensus()
        // cooViewer-oxr.54: cancel 済み measure の離脱前に再表示されても同じ
        // WKWebView へ新旧 census を並走させないよう、エンジンごと交換する。
        censusEngine?.invalidate()
        censusEngine = nil
        thumbnailRenderer?.invalidate()
        thumbnailRenderer = nil
        pauseMediaOverlay()
        discardPageCovers()
    }

    public override func viewDidUnhide() {
        super.viewDidUnhide()
        resumeDeferredVisibleWork()
    }

    private func resumeDeferredVisibleWork() {
        guard allowsVisibleRenderingWork else { return }
        resumePendingWebContentReloadIfNeeded()
        guard pendingVisibleLayout else {
            scheduleCensusIfNeeded()
            return
        }
        pendingVisibleLayout = false
        guard let webView else { return }
        layoutFurniture()
        layoutVisibleContent(webView, forcePagination: true)
        // 隠す・外すときに捨てた控えを撮り直す。固定レイアウトは再ページ割りを通らない。
        // リフローは runSetup の最後で撮り直す。
        if isFixedLayoutItem {
            schedulePageCoverPrefetchAfterFrames()
        }
    }
}
