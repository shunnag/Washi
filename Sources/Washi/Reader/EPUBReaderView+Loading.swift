import AppKit
import WebKit

/// EPUBReaderView の本の読み込み: load/unload と WebView の再構築、
/// spine 項目の読み込み・拒否・失敗時の打ち切りと復旧。
extension EPUBReaderView {
    // MARK: - 本の読み込み

    /// 本を開く。前回の位置から再開するには locator を渡す。
    /// ホストが追加したオーバーレイサブビューの重なり順は、Web ビューを
    /// 再構築しても保たれる。
    ///
    /// Opens a book. Pass a locator to resume from the previous position.
    /// Host-added overlay subviews keep their z-order across web view rebuilds.
    public func load(publication: EPUBPublication, at locator: EPUBLocator? = nil) {
        let hadPageCensus = pageCensus != nil
        guard let request = preparePublication(publication) else { return }
        // 保存位置は idref で突き合わせる(改版で spine が並べ替わった本でも
        // 別の章を無言で開かない。該当 idref が消えた本は先頭から)
        let resolved = locator.flatMap { publication.resolve($0) }
        let index = resolved.map {
            max(0, min($0.spineIndex, publication.readingOrder.count - 1))
        } ?? 0
        // 再オープン時も go(to:) と同じアンカーを使い、表示寸法の変更を吸収する。
        let target: PendingTarget
        if let resolved, let offset = resolved.textOffset {
            target = .textRange(utf16Offset: offset, utf16Length: 1,
                                fallbackProgression: resolved.progression)
        } else {
            target = resolved.map { .progression($0.progression) } ?? .start
        }
        spineLoad.pendingRestoreLocator = resolved
        rebuildWebView(for: publication)
        loadSpineItem(at: index, target: target)
        guard request == navigationRequestGeneration else { return }
        // 新しい publication・WebView・locator を揃えてから通知する。
        // 通知中に go/load されても、旧本の WebView で新本へ移動させない。
        // 内部再読込はここを通らないため、設定変更や WebContent 復旧では履歴を保つ。
        clearNavigationHistory()
        guard request == navigationRequestGeneration else { return }
        if hadPageCensus {
            delegate?.readerViewDidUpdatePageCensus(self)
        }
    }

    /// 本を閉じ、再生・描画処理と本に紐づく参照・キャッシュを解放する。
    /// ビューは再利用でき、次の本は `load(publication:at:)` で開ける。
    /// 設定と delegate は保持する。
    ///
    /// Closes the book and releases playback, rendering work, and book-related
    /// references and caches. The view can be reused with `load(publication:at:)`.
    /// Settings and the delegate are preserved.
    public func unload() {
        let hadPageCensus = pageCensus != nil
        guard let request = preparePublication(nil) else { return }
        // 破棄前に開始した setup・めくりの応答も、次の本へ持ち越さない。
        spineLoadGeneration += 1
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.stopLoading()
        webView?.removeFromSuperview()
        webView = nil
        schemeHandler = nil
        messageProxy?.owner = nil
        messageProxy = nil
        currentNavigation = nil
        spineLoad = SpineLoadState()
        spineNavigationGate = SpineNavigationGate()
        // 再ページ割りの予約は preparePublication が取り消し済み
        repagination = RepaginationState()
        currentSpineIndex = 0
        pageInItem = 0
        pageCountInItem = 1
        pagesPerScreen = 1
        isFixedLayoutItem = false
        scrollProgression = nil
        loadedScrollGroup = nil
        isImagePage = false
        isImageOnlyItem = false
        firstPageOnRight = false
        highlights.removeAll()
        clearPendingSpineTurn()
        for overlay in turn.turnOverlays { foldTurnCover(overlay) }
        updateFurniture()
        clearNavigationHistory()
        // 通知からの再入で開いた本を、外側の unload で再び閉じない。
        guard request == navigationRequestGeneration else { return }
        if hadPageCensus {
            delegate?.readerViewDidUpdatePageCensus(self)
        }
    }

    /// WebView の構築・破棄に先立つ共通の後始末。
    /// 本の状態遷移を分離し、実 WebKit を起動せずに解放の不変条件を検証する。
    @discardableResult
    func preparePublication(_ publication: EPUBPublication?) -> UInt? {
        mediaOverlayCommandGeneration &+= 1
        let request = beginNavigationRequest()
        cancelPendingTextRangeRequest()
        setCurrentSelection(nil)
        guard request == navigationRequestGeneration else { return nil }
        printPageMarkers.removeAll()
        setCurrentPrintPage(nil)
        guard request == navigationRequestGeneration else { return nil }
        accessibilityAnnouncementTask?.cancel()
        accessibilityAnnouncementTask = nil
        lastAnnouncedPage = nil
        // 本の差し替え・終了では位置も不要なので再生を完全に止める。
        mediaOverlayController?.stop()
        guard request == navigationRequestGeneration else { return nil }
        mediaOverlayController = nil
        pendingMediaOverlayHighlight = nil
        self.publication = publication
        // 前の本の控えを次の本に貼らない
        discardPageCovers()
        updateAccessibilityMetadata()
        webContentReload.task?.cancel()
        webContentReload = WebContentReloadState()
        columnAxisSupported = true
        fxlViewportCache = FixedLayoutViewportCache()
        // 旧本あての再ページ割り予約を破棄(新 webView に古い設定同期由来の
        // repaginate が発火しないように)
        repagination.repaginateWork?.cancel()
        repagination.repaginateWork = nil
        repagination.pendingRepaginate = false
        // census は本に紐づく(scheme handler ごと作り直す)
        census.task?.cancel()
        census.engine?.invalidate()  // 旧本のオフスクリーンを確実に畳む
        census = CensusState()
        thumbnailRenderer?.invalidate()  // サムネイルレンダラも本に紐づく
        thumbnailRenderer = nil
        pageCensus = nil
        return request
    }

    func reloadCurrentPublication() {
        guard let publication else { return }
        _ = beginNavigationRequest()
        let locator = currentLocator
        rebuildWebView(for: publication)
        loadSpineItem(at: locator.spineIndex, target: .progression(locator.progression))
    }

    private func rebuildWebView(for publication: EPUBPublication) {
        spineLoad.resetRecovery()
        // cooViewer-t4e: ホストが追加したオーバーレイを再構築後の webView で
        // 覆わないよう、旧 webView が占めていた z 位置を保存する。
        let oldWebViewIndex = webView.flatMap { subviews.firstIndex(of: $0) }
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.stopLoading()
        webView?.removeFromSuperview()
        messageProxy?.owner = nil
        spineNavigationGate = SpineNavigationGate()

        let handler = EPUBSchemeHandler(publication: publication,
                                        allowsScripts: settings.allowsScriptedContent)
        self.schemeHandler = handler

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript =
            settings.allowsScriptedContent
        configuration.setURLSchemeHandler(handler, forURLScheme: EPUBSchemeHandler.scheme)

        let proxy = MessageProxy(owner: self)
        self.messageProxy = proxy
        let controller = configuration.userContentController
        controller.add(proxy, contentWorld: WashiContentWorld.world, name: "washi")
        EPUBScriptedContentHardening.install(
            in: controller,
            allowsScriptedContent: settings.allowsScriptedContent)
        EPUBScrollDocument.install(in: controller, handler: handler)

        let webView = WashiWebView(frame: contentFrame,
                                   configuration: configuration)
        webView.contextMenuHandler = { [weak self] menu, event in
            self?.contextMenu(menu, for: event)
        }
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.autoresizingMask = []
        webView.alphaValue = 0  // 初回セットアップ完了までチラつきを隠す
        // WKWebView 自身のドロップ処理を外し、コンテナ(自ビュー)の
        // ファイルドロップ委譲を生かす(本は読み取り専用なので失うものはない)
        webView.unregisterDraggedTypes()
        if let oldWebViewIndex, subviews.indices.contains(oldWebViewIndex) {
            addSubview(webView, positioned: .below,
                       relativeTo: subviews[oldWebViewIndex])
        } else {
            addSubview(webView)
        }
        // ノンブルは Web ビューより前面に
        for label in pageNumberLabels {
            addSubview(label, positioned: .above, relativeTo: webView)
        }
        self.webView = webView

        Task { [weak webView] in
            if let ruleList = await Self.contentRuleList.value {
                webView?.configuration.userContentController.add(ruleList)
            }
        }
    }

    var isRollItem: Bool {
        guard effectiveFlow == .scrolledContinuous, let publication,
              publication.readingOrder.indices.contains(currentSpineIndex) else { return false }
        return publication.package.effectiveLayout(
            for: publication.readingOrder[currentSpineIndex].itemRef) != .reflowable
    }

    func loadSpineItem(at index: Int, target: PendingTarget,
                               preservingTurnCover: Bool = false,
                               isRecovery: Bool = false) {
        let request = navigationRequestGeneration
        let previousGeneration = spineLoadGeneration
        let isTextRangeTarget: Bool
        if case .textRange = target {
            isTextRangeTarget = true
        } else {
            isTextRangeTarget = false
        }
        guard let publication, let schemeHandler, let webView,
              publication.readingOrder.indices.contains(index) else {
            if isTextRangeTarget { cancelPendingTextRangeRequest() }
            return
        }
        let entry = publication.readingOrder[index]
        let url = spineLoadURL(at: index)
        let failure = Self.spineLoadFailure(entry, in: publication, url: url)
        if let failure, webView.url != nil, !isRecovery {
            // 入口でも検証するが、内部経路から届いた拒否も状態変更前に止める。
            if isTextRangeTarget { cancelPendingTextRangeRequest() }
            reportRejectedNavigation(failure)
            return
        }
        if !isTextRangeTarget { cancelPendingTextRangeRequest() }
        // cooViewer-oxr.47: 旧 spine の WebContent 終了に対するバックオフを、
        // ユーザーが移動した新 spine へ遅配しない。
        webContentReload.task?.cancel()
        webContentReload.task = nil
        webContentReload.pendingDelay = nil
        setCurrentSelection(nil)
        guard request == navigationRequestGeneration,
              previousGeneration == spineLoadGeneration,
              webView === self.webView else { return }
        spineNavigationGate.dropTerminatedProcessExpectations()
        if spineLoad.recovery.isShowingSetUpDocument {
            spineLoad.recovery.settledLocator = currentLocator
        }
        spineLoad.recovery.isShowingSetUpDocument = false
        spineLoad.recovery.isRecoveryLoad = isRecovery
        // currentSpineIndex を書き換える前に控えを取り置く
        armSpineCoverForTransition()
        printPageMarkers.removeAll(keepingCapacity: true)
        accessibilityAnnouncementTask?.cancel()
        accessibilityAnnouncementTask = nil
        currentSpineIndex = index
        spineLoad.pendingTarget = target
        // cooViewer-oxr.23: pageChanged 前の保存にも、読み込み先の意図した
        // progression を返せるよう locator として保持する。
        spineLoad.pendingRestoreLocator = locator(for: target, at: index)
        pageInItem = 0
        pageCountInItem = 1
        scrollProgression = nil
        isImagePage = false
        isImageOnlyItem = false
        // setup 応答までは OPF を暫定値にし、旧 item の CSS 方向を持ち越さない。
        firstPageOnRight = isRTL
        spineLoad.isLoadingSpineItem = true
        pendingMediaOverlayHighlight = nil
        spineLoadGeneration += 1
        // コミット前に置き換わった読み込みの矩形を、新しい項目へ当てない
        spineLoad.pendingWebViewLayout = nil
        repagination.repaginateWork?.cancel()  // 旧文書あての再ページ割りを新文書へ流さない
        // 進行中のめくり演出は新しい章の表示を隠すので畳む。
        // spine 遷移演出の持ち越しカバー(旧ページ)は読み込み中も残す。
        // 控えのカバーは演出なしで畳むだけなので、目次・リンクなどのジャンプでも
        // 最新の項目の表示まで残す(Washi-3b1)。url は load で仮の URL になる前に調べ、
        // 作り直したばかりの WebView(url が nil)では前の控えを畳む。
        // foldTurnCover 経由で各カバーの時間切れ回収タスクも確実に止める
        let keepsPageCover = turn.pendingSpineTurn?.animated == false && webView.url != nil
        if !preservingTurnCover && !keepsPageCover { clearPendingSpineTurn() }
        let survivor = turn.pendingSpineTurn?.cover
        for overlay in turn.turnOverlays where overlay !== survivor {
            foldTurnCover(overlay)
        }
        loadedScrollGroup = effectiveFlow == .scrolledContinuous
            ? publication.scrollGroup(containing: index) : nil
        isFixedLayoutItem =
            publication.package.effectiveLayout(for: entry.itemRef) == .prePaginated
            && !EPUBScreenMetrics.isScrolled(effectiveFlow)
        // 画像 1 枚だけの項目(表紙・挿絵)は余白を使わず全面に置く。ページ割りの前に
        // 決めておく。scrolled は対象外(ページ数が高さに依存するため。ReaderScripts の
        // imagePage && !scrolled と同じ)。判定は publication がキャッシュし、
        // census・サムネイルも同じ答えを使う
        if isFixedLayoutItem || EPUBScreenMetrics.isScrolled(effectiveFlow) {
            isImageOnlyItem = false
        } else {
            isImageOnlyItem = publication.isSingleImageItem(atSpineIndex: index)
        }
        // 新しい項目の矩形と倍率は読み込み前に決め、当てるのは didCommit にする。
        // WebKit はコミットまで旧文書を描き続けるので、ここで当てると旧ページが
        // 新しい矩形・倍率で一瞬描かれる。setup は didFinish の後なので、
        // ページ割りは新しい寸法で行われる(cooViewer-oxr.51)。
        // FXL は宣言された viewport から矩形を決める(描いてから測って動かさない)。
        // 旧文書が無いか透明なら見えないので即時に当てる。
        let targetLayout: (frame: NSRect, zoom: CGFloat)? = isFixedLayoutItem
            ? fixedItemLayout() : (contentFrame, 1)
        if let layout = targetLayout {
            let unchanged = webView.frame == layout.frame
                && webView.pageZoom == layout.zoom
            if unchanged || webView.url == nil || webView.alphaValue == 0 {
                applyWebViewLayout(layout.frame, zoom: layout.zoom)
            } else {
                spineLoad.pendingWebViewLayout = (layout.frame, layout.zoom, spineLoadGeneration)
            }
        }
        spineLoad.isAwaitingCommit = webView.url != nil && webView.alphaValue > 0
        updateFurniture()
        if let failure {
            reportNavigationFailure(failure)
            return
        }
        guard let url else { return }  // URL が無い場合は上の失敗判定で処理済み。
        // 透明にするのは didCommit(それまでは前のページが見えている)
        let navigationPath = schemeHandler.containerPath(for: url) ?? entry.resolvedContainerPath
        spineNavigationGate.expect(navigationPath, generation: spineLoadGeneration)
        let urlRequest = URLRequest(url: url)
        let navigation: WKNavigation?
        if let spineLoadHandler {
            navigation = spineLoadHandler(urlRequest)
        } else {
            navigation = webView.load(urlRequest)
        }
        if navigation == nil {
            spineNavigationGate.cancelExpectation(for: navigationPath)
            reportNavigationFailure(EPUBError.malformed(
                "Cannot load spine resource: \(entry.resolvedContainerPath)"))
            // 入れ子で始まった読み込み直しの navigation を nil で上書きしない。
            return
        }
        currentNavigation = navigation
    }

    func canRenderSpine(at index: Int) -> Bool {
        guard let publication, publication.readingOrder.indices.contains(index) else { return false }
        return publication.canRenderSpineResource(publication.readingOrder[index])
    }

    /// 読み込めない理由。描画可能な fallback と URL を状態変更前に検証する。
    static func spineLoadFailure(
        _ entry: ReadingOrderItem, in publication: EPUBPublication, url: URL?
    ) -> EPUBError? {
        guard publication.canRenderSpineResource(entry) else {
            return .malformed(
                "Cannot display spine resource: \(entry.containerPath) (no renderable fallback)")
        }
        guard url != nil else {
            return .malformed("Cannot load spine resource: \(entry.resolvedContainerPath)")
        }
        return nil
    }

    private func spineLoadURL(at index: Int) -> URL? {
        guard let publication, let schemeHandler,
              publication.readingOrder.indices.contains(index) else { return nil }
        // effectiveFlow は現在位置を読むため、検証では移動先の flow を直接調べる。
        if publication.renderingFlow(at: index) == .scrolledContinuous {
            return schemeHandler.scrollDocumentURL
        }
        return schemeHandler.url(forReadingOrderItem: publication.readingOrder[index])
    }

    func spineLoadFailure(at index: Int) -> EPUBError? {
        guard let publication, publication.readingOrder.indices.contains(index) else { return nil }
        return Self.spineLoadFailure(publication.readingOrder[index], in: publication,
                                     url: spineLoadURL(at: index))
    }

    func rejectsUnloadableNavigation(to index: Int) -> Bool {
        guard webView?.url != nil, let failure = spineLoadFailure(at: index) else { return false }
        reportRejectedNavigation(failure)
        return true
    }

    /// 拒否では進行中の読み込み・範囲要求・カバー・印刷ページもそのまま保つ。
    func reportRejectedNavigation(_ error: any Error) {
        delegate?.readerView(self, didFailWith: error)
    }

    /// 失敗・WebContent 終了時の読み込みを打ち切る。復旧時だけ、コミット待ちの
    /// 控えと貼付済みの静止カバーを次の loadSpineItem へ引き継ぐ(Washi-k0x)。
    func abandonSpineLoad(preservingPageCover: Bool = false) {
        cancelPendingTextRangeRequest()
        spineLoad.isLoadingSpineItem = false
        pendingMediaOverlayHighlight = nil
        currentNavigation = nil
        spineNavigationGate.abandonPendingExpectations()
        webView?.stopLoading()
        spineLoad.pendingWebViewLayout = nil
        if !preservingPageCover {
            pageCover.armedSpineCover = nil
            spineLoad.isAwaitingCommit = false
        }
        if !preservingPageCover || turn.pendingSpineTurn?.animated != false {
            clearPendingSpineTurn()
        }
        let survivor = turn.pendingSpineTurn?.cover
        for overlay in turn.turnOverlays where overlay !== survivor { foldTurnCover(overlay) }
    }

    /// 保存した位置にテキストの錨があれば同じ文へ、無ければ進行率へ戻る。
    private static func target(restoring locator: EPUBLocator) -> PendingTarget {
        guard let offset = locator.textOffset else { return .progression(locator.progression) }
        return .textRange(utf16Offset: offset, utf16Length: 1,
                          fallbackProgression: locator.progression)
    }

    /// 読み込み開始後の失敗は最後に setup を終えた位置を読み込み直す。
    /// 復旧自体の失敗や復旧先が無い場合は、その項目で止める。通知前に行き先を
    /// 決め、通知中にホストが始めた移動を後から上書きしない。
    func reportNavigationFailure(_ error: any Error) {
        if let settledLocator = spineLoad.recovery.settledLocator,
           !spineLoad.recovery.isRecoveryLoad {
            // コミット前の isAwaitingCommit と armedSpineCover は、次の読み込みが
            // 控えを引き継ぐために残す。コミット済みなら未整形の文書を見せない。
            let awaitingCommit = spineLoad.isAwaitingCommit
            abandonSpineLoad(preservingPageCover: true)
            webView?.alphaValue = awaitingCommit ? 1 : 0
            _ = beginNavigationRequest()
            loadSpineItem(at: settledLocator.spineIndex,
                          target: Self.target(restoring: settledLocator), isRecovery: true)
        } else {
            abandonSpineLoad()
            spineLoad.resetRecovery()
            webView?.alphaValue = 1
            let request = navigationRequestGeneration
            updateCurrentPrintPage()
            if request == navigationRequestGeneration { updateFurniture() }
        }
        delegate?.readerView(self, didFailWith: error)
    }
}
