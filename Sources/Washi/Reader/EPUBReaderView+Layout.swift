import AppKit
import OSLog
import WebKit

/// EPUBReaderView のレイアウトと再ページ割り: 余白と本文領域、画面計画
/// (EPUBScreenMetrics)、WebView の配置、setup/repaginate の実行と結果の反映、
/// 設定変更の反映(再ページ割りか配色だけかの振り分け)。
extension EPUBReaderView {
    // MARK: - 設定変更の反映

    /// settings の didSet。組版に効く変更は進行率を保った再ページ割り、配色だけの
    /// 変更は CSS の差し替えで反映する。直接代入では didChangeFontScale を出さない
    /// (adjustFontScale(by:) とピンチだけが出す)
    func applySettingsChange(from oldValue: EPUBReaderSettings) {
        guard oldValue != settings else { return }
        let layoutChanged = layoutKey(for: oldValue) != layoutKey(for: settings)
        applyTheme()
        updateAccessibilityMetadata()
        if oldValue.announcesPageChanges && !settings.announcesPageChanges {
            accessibilityAnnouncementTask?.cancel()
            accessibilityAnnouncementTask = nil
        }
        if oldValue.forwardsKeyEventsNatively
            != settings.forwardsKeyEventsNatively {
            updateNativeKeyMonitor()
        }
        if oldValue.handlesKeyboardNavigation
            != settings.handlesKeyboardNavigation {
            // cooViewer-oxr.24: setup 後の切替も現在の文書へ即時反映する。
            evaluate("__washi.setKeysEnabled(\(settings.handlesKeyboardNavigation));")
        }
        if oldValue.defersTapsForDoubleClick
            != settings.defersTapsForDoubleClick {
            // cooViewer-oxr.27: ページ割りを伴わない入力設定も現在文書へ即時反映する。
            updateTapDeferral()
        }
        if oldValue.allowsScriptedContent != settings.allowsScriptedContent {
            // JS 許可はビュー構成ごと作り直す(WKWebViewConfiguration は不変)
            reloadCurrentPublication()
        } else if layoutChanged {
            // cooViewer-oxr.24: 個別フィールド列挙ではなく census と同じ
            // 導出キーを正とし、userCSS を含む変更漏れを防ぐ。
            needsLayout = true
            // 組版(同じ代入で変えた配色を含む)が変わるので今の控えは使えない。
            // 撮り直しは runSetup の最後。
            dropPrefetchedPageCover()
            schedulePagination(preserveProgression: true)
        } else {
            // 配色・めくり演出・柱の表示などはページ割りを保ったまま反映
            let appearanceChanged = oldValue.composedUserCSS(
                isDark: isDark(for: oldValue.theme),
                increaseContrast: shouldIncreaseContrast,
                differentiateWithoutColor: shouldDifferentiateWithoutColor)
                != settings.composedUserCSS(
                    isDark: isDark(for: settings.theme),
                    increaseContrast: shouldIncreaseContrast,
                    differentiateWithoutColor: shouldDifferentiateWithoutColor)
            // 配色の CSS が変わらない設定(キー操作・読み上げの通知・柱の表示など)では控えを捨てない。
            applyThemeCSSOnly(retakesCover: appearanceChanged)
            updateFurniture()
        }
    }

    /// リフロー時の webView 配置(設定の余白でインセット)。
    /// FXL・roll・画像 1 枚だけの項目は全面(余白なし)に配置してページ自体を版面として見せる
    /// 現在の表示モード(単ページ/見開き)に応じた実効余白。見開きは
    /// spreadInsets があればそちら、無ければ insets(EPUBScreenMetrics と同じ規則)
    var activeInsets: EPUBReaderInsets {
        return isSpread ? (settings.spreadInsets ?? settings.insets)
                        : settings.insets
    }

    /// 見開き判定は現在 itemref の実効 rendition:spread を含む画面計画へ一本化する
    private var isSpread: Bool {
        currentScreenMetrics.pagesPerScreen == 2
    }

    /// 現在のネイティブ余白の内側にある本文ページ領域。
    /// リーダービューの座標系で表す。FXL・roll・画像 1 枚だけの項目(表紙・挿絵)では
    /// 余白を使わず、ビューの全面を返す。spine 項目の読み込み中は、新しい項目の
    /// 領域を返す(WebView には新しい文書のコミット時に当てる)。
    ///
    /// The content page area inside the active native margins, expressed in
    /// reader-view coordinates. For FXL, roll, and single-image items (cover,
    /// illustration), this returns the full view with no margins. While a spine
    /// item is loading, this returns the new item's area; the web view adopts it
    /// when the new document commits.
    public var contentFrame: CGRect {
        // census・サムネイルは EPUBScreenMetrics.fillsViewport で同じ判断をする
        if isFixedLayoutItem || isRollItem || isImageOnlyItem {
            return NSRect(origin: .zero, size: bounds.size)
        }
        let insets = activeInsets
        return NSRect(
            x: insets.left,
            y: insets.bottom,
            width: max(1, bounds.width - insets.left - insets.right),
            height: max(1, bounds.height - insets.top - insets.bottom))
    }

    // 見開き判定・ノド幅は EPUBScreenMetrics が単一の正(リーダー外の
    // 一覧展開と式を共有し、ページ割りの一致を保証する)

    func spreadGutter(forContentWidth width: CGFloat) -> CGFloat {
        EPUBScreenMetrics.spreadGutter(forContentWidth: width)
    }

    /// 現在の表示条件の画面計画(census・サムネイルのオプションもここから)
    var currentScreenMetrics: EPUBScreenMetrics {
        EPUBScreenMetrics(
            viewportSize: bounds.size, settings: settings,
            renditionSpread: effectiveSpread(forSpineIndex: currentSpineIndex))
            .applyingRenditionFlow(effectiveFlow)
    }

    /// cooViewer-oxr.24: ライブ再ページ割りの判定にも census と同じ導出値を使う。
    func layoutKey(for settings: EPUBReaderSettings) -> String {
        EPUBScreenMetrics(
            viewportSize: bounds.size, settings: settings,
            renditionSpread: effectiveSpread(forSpineIndex: currentSpineIndex))
            .applyingRenditionFlow(effectiveFlow)
            .cacheKey
    }

    /// census のキーは表示中の項目で揺らさず、文書既定を基底にする。
    /// 実測時は EPUBPaginationCensus が各 itemref の override を適用する。
    var censusScreenMetrics: EPUBScreenMetrics {
        EPUBScreenMetrics(
            viewportSize: bounds.size, settings: settings,
            renditionSpread: publication?.metadata.rendition.spread ?? .auto)
            .applyingRenditionFlow(publication?.metadata.rendition.layout == .roll
                ? .scrolledContinuous : (publication?.metadata.rendition.flow ?? .auto))
    }

    func effectiveSpread(forSpineIndex index: Int) -> RenditionSpread {
        guard let publication,
              publication.readingOrder.indices.contains(index) else {
            return publication?.metadata.rendition.spread ?? .auto
        }
        // cooViewer-oxr.51: 見開き可否は現在項目の itemref override を使う。
        return publication.package.effectiveSpread(
            for: publication.readingOrder[index].itemRef)
    }

    // MARK: - レイアウト

    public override func layout() {
        super.layout()
        layoutFurniture()
        guard let webView else { return }
        guard allowsVisibleRenderingWork else {
            // cooViewer-oxr.54: 非表示中は WebKit の再ページ割りと census を
            // 起動せず、最後の寸法を表示復帰時に一度だけ反映する。
            repagination.pendingVisibleLayout = true
            return
        }
        layoutVisibleContent(webView, forcePagination: false)
    }

    var allowsVisibleRenderingWork: Bool {
        window != nil && !isHiddenOrHasHiddenAncestor
    }

    func layoutVisibleContent(_ webView: WKWebView,
                                      forcePagination: Bool) {
        if isFixedLayoutItem {
            layoutFixedItem()
            // FXL 項目の表示中でもリサイズで census のメトリクスは変わる
            // (再ページ割りは不要だが、N/M とジャンプ写像は寸法依存)。
            // scheduleCensusIfNeeded はキーで重複排除するので毎回呼んで安全
            scheduleCensusIfNeeded()
        } else {
            placeWebView(contentFrame, zoom: 1)
            if forcePagination || repagination.lastLaidOutSize != bounds.size {
                schedulePagination(preserveProgression: true)
            }
        }
        repagination.lastLaidOutSize = bounds.size
    }

    /// FXL: ICB へのアスペクトフィット。中央寄せは webView フレームで行う。
    /// viewport はキャッシュする(リサイズ毎の XHTML 再パースを避ける)
    func layoutFixedItem() {
        guard let layout = fixedItemLayout() else { return }
        placeWebView(layout.frame, zoom: layout.zoom)
    }

    /// WebView の矩形と倍率を当てる。コミット待ちの間は、当てる予定の値だけを更新する
    private func placeWebView(_ frame: NSRect, zoom: CGFloat) {
        if spineLoad.pendingWebViewLayout != nil {
            spineLoad.pendingWebViewLayout?.frame = frame
            spineLoad.pendingWebViewLayout?.zoom = zoom
            return
        }
        applyWebViewLayout(frame, zoom: zoom)
    }

    /// コミット待ちの矩形と倍率を当てる(同じ読み込みのものに限る)。
    func applyPendingWebViewLayout() {
        guard let pending = spineLoad.pendingWebViewLayout else { return }
        spineLoad.pendingWebViewLayout = nil
        guard pending.generation == spineLoadGeneration else { return }
        applyWebViewLayout(pending.frame, zoom: pending.zoom)
    }

    /// FXL の収まる矩形と倍率(宣言された viewport と contentFrame から決まる)。
    func fixedItemLayout() -> (frame: NSRect, zoom: CGFloat)? {
        guard webView != nil, let publication else { return nil }
        let available = contentFrame
        let viewport = fxlViewportCache.viewport(
            forSpineIndex: currentSpineIndex, available: available.size,
            publication: publication)
        guard viewport.width > 0, viewport.height > 0,
              available.width > 0, available.height > 0 else { return nil }
        let scale = min(available.width / viewport.width,
                        available.height / viewport.height)
        let size = NSSize(width: viewport.width * scale,
                          height: viewport.height * scale)
        let fitted = NSRect(
            x: available.minX + (available.width - size.width) / 2,
            y: available.minY + (available.height - size.height) / 2,
            width: size.width, height: size.height)
        return (fitted, scale)
    }

    func applyWebViewLayout(_ fitted: NSRect, zoom scale: CGFloat) {
        guard let webView else { return }
        webView.frame = fitted
        webView.pageZoom = scale
    }

    /// リサイズ・設定変更後の再ページ割り(連続リサイズをデバウンス)。
    /// セットアップ実行中に届いた要求は捨てずに完了後へ繰り越す(捨てると
    /// lastLaidOutSize が先に更新され、以後そのサイズでは再ページ割りされない)
    func schedulePagination(preserveProgression: Bool) {
        guard webView != nil, publication != nil else { return }
        guard allowsVisibleRenderingWork else {
            // cooViewer-oxr.54: 設定変更経路も不可視中は同じ延期状態へ畳む。
            repagination.pendingVisibleLayout = true
            return
        }
        // spine 読み込み中(didFinish 前)は再ページ割りを走らせない。
        // ここで走らせると、文書のロード完了前に repaginate が isLoadingSpineItem
        // や alpha を早期リセットして、旧文書の境界イベント受理や表示のちらつきを
        // 招く(世代トークンは同一世代なので防げない)。didFinish 後の
        // runSetup 完了時に defer が pendingRepaginate を拾って正しい順序で走る
        if spineLoad.isSettingUp || spineLoad.isLoadingSpineItem {
            repagination.pendingRepaginate = true
            return
        }
        repagination.repaginateWork?.cancel()
        let generation = spineLoadGeneration
        repagination.repaginateWork = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            await self?.runSetup(preserveProgression: preserveProgression,
                                 generation: generation)
        }
    }

    func setupOptionsJSON() -> String {
        let frame = contentFrame
        var options: [String: Any] = [
            "width": Double(frame.width.rounded(.down)),
            "height": Double(frame.height.rounded(.down)),
            "gap": settings.pageGap,
            "spread": isSpread,
            "gutter": Double(spreadGutter(forContentWidth: frame.width)),
            "fixedLayout": isFixedLayoutItem,
            "flow": effectiveFlow.rawValue,
            "keysEnabled": settings.handlesKeyboardNavigation,
            // cooViewer-oxr.46 C35: 通知が今の文書のものかを判別する印。
            "documentToken": currentDocumentToken,
            // cooViewer-oxr.27: 既定は即時。明示 opt-in 時だけ click を保留する。
            "deferTaps": settings.defersTapsForDoubleClick,
            "fontScale": settings.fontScale,
            "defaultFontCSS": settings.defaultFontCSS(),
            "userCSS": settings.composedUserCSS(
                isDark: isDarkEffective,
                increaseContrast: shouldIncreaseContrast,
                differentiateWithoutColor: shouldDifferentiateWithoutColor),
        ]
        if settings.defersTapsForDoubleClick {
            let interval = NSEvent.doubleClickInterval
            options["doubleClickDelayMS"] = 1_000 * (interval > 0 ? interval : 0.5)
        }
        if isFixedLayoutItem { options["width"] = 0; options["height"] = 0 }
        let data = (try? JSONSerialization.data(withJSONObject: options)) ?? Data("{}".utf8)
        let json = String(data: data, encoding: .utf8) ?? "{}"
        guard let publication, let schemeHandler else { return json }
        return EPUBScrollDocument.options(json, publication: publication,
                                          index: currentSpineIndex, handler: schemeHandler)
    }

    /// JS へ復元先の適用を依頼した時点では実位置が未確定なので、locator は
    /// pageChanged が届くまで保持する
    func applyPendingTargetAfterSetup() {
        applyTarget(spineLoad.pendingTarget)
    }

    /// didFinish 後(または再ページ割り時)のセットアップ実行。
    /// generation が現在の spine 読み込み世代と食い違ったら何もしない
    /// (guard は JS await の後にも必要 — await 中に別の spine へ
    /// 移っていたら、その文書の状態を消費・破壊してはならない)
    func runSetup(preserveProgression: Bool, generation: Int) async {
        guard let webView, generation == spineLoadGeneration else { return }
        spineLoad.isSettingUp = true
        defer {
            spineLoad.isSettingUp = false
            // 実行中に届いた再ページ割り(リサイズ・設定変更)を後追いする
            if repagination.pendingRepaginate {
                repagination.pendingRepaginate = false
                schedulePagination(preserveProgression: true)
            }
        }
        let call = preserveProgression
            ? "return __washi.repaginate(\(setupOptionsJSON()));"
            : "return __washi.setup(\(setupOptionsJSON()));"
        do {
            let result = try await webView.callAsyncJavaScript(
                call, arguments: [:], in: nil, contentWorld: WashiContentWorld.world)
            guard !Task.isCancelled,
                  generation == spineLoadGeneration,
                  webView === self.webView else { return }
            settleDocument(after: result, preserveProgression: preserveProgression,
                           generation: generation)
            guard generation == spineLoadGeneration,
                  webView === self.webView else { return }
            await revealAfterSetup(webView: webView, generation: generation)
        } catch {
            guard !Task.isCancelled else { return }
            // 古い文書の JS 失敗で新しい文書の読み込み状態を壊さない
            guard generation == spineLoadGeneration else { return }
            if !preserveProgression {
                spineLoad.resetRecovery()
            }
            cancelPendingTextRangeRequest()
            spineLoad.isLoadingSpineItem = false
            pendingMediaOverlayHighlight = nil
            clearPendingSpineTurn()
            webView.alphaValue = 1
            delegate?.readerView(self, didFailWith: error)
        }
    }

    /// setup / repaginate の応答を状態へ写し、初回は読み込み中の gate を解いて
    /// 予約した target を適用する(runSetup の JS 応答直後。await を挟まない)
    private func settleDocument(after result: Any?, preserveProgression: Bool,
                                generation: Int) {
        if let dict = result as? [String: Any] {
            applySetupResult(dict)
        }
        // cooViewer-oxr.46 C40: ページ割りが決まった後に描き直す
        // (Range は文書に紐づくので、再ページ割りでも作り直す必要がある)
        applyHighlights()
        if !preserveProgression {
            spineNavigationGate.dropExpectations(through: generation)
            // フレーム待ち中に次の移動が始まっても、この文書を復旧先にする。
            spineLoad.recovery.isShowingSetUpDocument = true
            spineLoad.recovery.settledLocator = nil
            spineLoad.recovery.isRecoveryLoad = false
            // cooViewer-oxr.23: 新文書の target が発行する pageChanged は
            // 受けつつ、それ以前の旧文書通知だけを loading gate で捨てる。
            spineLoad.isLoadingSpineItem = false
            applyPendingTargetAfterSetup()
        }
        spineLoad.isLoadingSpineItem = false
        spineLoad.pendingTarget = .start
        if let highlight = pendingMediaOverlayHighlight {
            pendingMediaOverlayHighlight = nil
            // 新しい章の最初の区間を、表示を戻す前に強調する。
            // setup 中の撮影予約は何もしないので、下の撮影にまとめる。
            mediaOverlayHighlight(fragmentID: highlight.fragmentID,
                                  cssClass: highlight.cssClass)
        }
        updateFurniture()
        scheduleCensusIfNeeded()  // メトリクス変化(フォント・寸法)に追従
    }

    /// 描画フレームを待ってから表示を戻し、控えを撮り直して持ち越しカバーを畳む
    /// (runSetup の末尾。await の後は世代と webView を確かめてから続ける)
    private func revealAfterSetup(webView: WKWebView, generation: Int) async {
        // 透明から戻すときは、描画フレームが 2 回進むのを待つ。直後はまだ前の
        // フレームが合成されていて、引き伸ばされた古い絵が一瞬見えるため。
        // 既に見えている再ページ割りでは待たない
        if webView.alphaValue < 1 {
            let wait = animationFrameWait
            _ = await TimeoutRace.run({ await wait(webView) },
                                      timeout: animationFrameWaitTimeout)
            guard generation == spineLoadGeneration,
                  webView === self.webView else { return }
        }
        webView.alphaValue = 1  // 持ち越しカバーがあればその下で戻る
        // 次の spine 遷移にそなえて控えを撮り直す(カバーを畳んだ後に走る)
        schedulePageCoverPrefetch()
        if let pending = turn.pendingSpineTurn, !pending.animated {
            // 控えのカバーは、新しいページが合成された今の時点で演出なしに畳む
            turn.pendingSpineTurn = nil
            foldTurnCover(pending.cover)
        } else if let pending = turn.pendingSpineTurn {
            await finishPendingSpineTurn(pending, webView: webView, generation: generation)
        }
    }

    /// cooViewer-oxr.48: JS の機能検出結果を公開状態へ写し、縦見開きの
    /// 単ページ縮退を診断可能にする。
    func applySetupResult(_ result: [String: Any]) {
        if let count = result["pageCount"] as? Int {
            pageCountInItem = max(1, count)
        }
        isImagePage = result["imagePage"] as? Bool ?? false
        pagesPerScreen = max(1, result["pagesPerScreen"] as? Int ?? 1)
        if let measured = result["firstPageOnRight"] as? Bool {
            firstPageOnRight = measured
        }
        if let markers = result["printPageMarkers"] as? [[String: Any]] {
            // cooViewer-oxr.38: JS の文書順を保ち、壊れた値だけを捨てる。
            printPageMarkers = markers.compactMap { marker in
                guard let label = marker["label"] as? String, !label.isEmpty,
                      let page = marker["page"] as? Int, page >= 0 else {
                    return nil
                }
                return PrintPageMarker(label: label, page: page)
            }
        }
        guard let supported = result["supportsColumnAxis"] as? Bool else { return }
        let shouldLog = columnAxisSupported && !supported && isSpread
            && ["vrl", "vlr"].contains(result["mode"] as? String ?? "")
        columnAxisSupported = supported
        if shouldLog {
            Self.logger.warning(
                "Vertical spread fell back to one page because column-axis is unsupported")
        }
    }
}
