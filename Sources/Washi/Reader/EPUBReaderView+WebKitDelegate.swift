import AppKit
import WebKit

// MARK: - WKNavigationDelegate / WKUIDelegate

/// EPUBReaderView の WKNavigationDelegate / WKUIDelegate: 遷移の許可判定、
/// コミットと完了・失敗の受け取り、WebContent プロセス終了時の再読み込み。
extension EPUBReaderView: WKNavigationDelegate, WKUIDelegate {
    public func webView(_ webView: WKWebView,
                        decidePolicyFor navigationAction: WKNavigationAction,
                        preferences: WKWebpagePreferences) async
        -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        guard webView === self.webView,
              let url = navigationAction.request.url else {
            return (.cancel, preferences)
        }
        if url.scheme?.lowercased() == EPUBSchemeHandler.scheme {
            // コンテナ内 iframe は spine の期待値を消費せず、そのフレーム内で
            // 読み込む。外部スキームにはこの例外を適用せず、従来どおり遮断する。
            guard navigationAction.targetFrame?.isMainFrame != false else {
                return (.allow, preferences)
            }
            guard let path = schemeHandler?.containerPath(for: url) else {
                return (.cancel, preferences)
            }
            switch spineNavigationGate.disposition(
                for: path, navigationType: navigationAction.navigationType) {
            case .allowExpectedLoad:
                preferences.allowsContentJavaScript = settings.allowsScriptedContent
                return (.allow, preferences)
            case .cancelAbandonedLoad:
                return (.cancel, preferences)
            case .routeThroughReader:
                // 文書が発行した遷移は種類を問わず直接通さず、spine・locator・
                // ページ割りを同時に更新する共通経路へ戻す
                goToContainerPath(
                    path, fragment: url.fragment(percentEncoded: false))
                return (.cancel, preferences)
            }
        }
        // JS のクリック捕捉をすり抜けたリンク(area 等)の安全網
        if Self.externalLinkSchemes.contains(url.scheme?.lowercased() ?? ""),
           navigationAction.navigationType == .linkActivated {
            openExternalURLIfAllowed(url)
        }
        return (.cancel, preferences)
    }

    /// 新しい文書のコミット時に WebView を透明にし、読み込み前に決めた矩形と倍率を
    /// 当てる。コミットまでは WebKit が前の文書を描き続けるので、前のページが
    /// 見えたままになる。控えのスナップショットがあれば、同時にカバーとして貼る。
    /// 表示は setup の完了後に戻す。
    /// 新しい読み込みのコミットを待つ間に、置き換えられた前の読み込みの文書が
    /// コミットされた場合も、同じく透明にする(ページ割り前の文書を見せない)。
    /// このときも、前のページの控えがあればカバーとして貼る。
    ///
    /// Makes the web view transparent when the new document commits and applies
    /// the frame and zoom decided before loading. Until the commit, WebKit keeps
    /// drawing the previous document, so the previous page stays visible. A
    /// prepared snapshot of that page, if any, is installed as a cover at the
    /// same time. The view becomes visible again after setup completes.
    /// The same applies when a superseded earlier load commits while a newer
    /// load is still awaiting its commit, so an unpaginated document is never shown.
    /// The prepared snapshot of the previous page, if any, is installed as a cover
    /// in that case too.
    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        // 次の読み込みが前のページを見せたままコミットを待つ間に、置き換えた前の
        // 読み込みの文書がコミットされることがある(その didCommit の配達より先に
        // loadSpineItem が走った場合)。WebKit はもう前のページではなく、ページ割り前の
        // 文書を描いているので、次の読み込みのコミットと同じく透明にして、次の項目の
        // 矩形と倍率を当てる(Washi-7ct)
        guard webView === self.webView,
              navigation == nil || navigation === currentNavigation
                  || spineLoad.isAwaitingCommit else { return }
        // 演出のカバーが既にあるときは横取りしない
        if turn.pendingSpineTurn == nil, let armed = pageCover.armedSpineCover {
            installSpineCover(armed)
        }
        pageCover.armedSpineCover = nil
        webView.alphaValue = 0
        applyPendingWebViewLayout()
        spineLoad.isAwaitingCommit = false
        updateFurniture()
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // 別の spine へ移った後に届いた古い didFinish は無視する
        // (これを通すと古いセットアップが新文書の pendingTarget を消費する)
        guard webView === self.webView,
              navigation == nil || navigation === currentNavigation else { return }
        // 通常は didCommit で当たっている。取り残しがあればここで当てる
        applyPendingWebViewLayout()
        spineLoad.isAwaitingCommit = false
        if isFixedLayoutItem {
            layoutFixedItem()
        }
        let generation = spineLoadGeneration
        Task { [weak self] in
            await self?.runSetup(preserveProgression: false,
                                 generation: generation)
        }
    }

    /// 102 は表示不能な応答でも届くため、文書発行の遷移を拒否した
    /// navigation == nil の場合だけ正常なキャンセルとする。現在の読み込みに
    /// 属する 102 は、MIME 宣言が描画可能でも失敗通知を優先する。
    static func isExpectedNavigationCancellation(
        _ error: any Error, hasNavigation: Bool
    ) -> Bool {
        let nsError = error as NSError
        return (nsError.domain == NSURLErrorDomain
                && nsError.code == NSURLErrorCancelled)
            || (nsError.domain == "WebKitErrorDomain" && nsError.code == 102
                && !hasNavigation)
    }

    func handleNavigationFailure(_ error: any Error, hasNavigation: Bool) {
        guard !Self.isExpectedNavigationCancellation(error, hasNavigation: hasNavigation)
        else { return }
        reportNavigationFailure(error)
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!,
                        withError error: any Error) {
        // 別 spine へ移った後に届く古い失敗は無視(新文書の状態を壊さない)
        guard webView === self.webView,
              navigation == nil || navigation === currentNavigation else { return }
        handleNavigationFailure(error, hasNavigation: navigation != nil)
    }

    public func webView(_ webView: WKWebView,
                        didFailProvisionalNavigation navigation: WKNavigation!,
                        withError error: any Error) {
        guard webView === self.webView,
              navigation == nil || navigation === currentNavigation else { return }
        handleNavigationFailure(error, hasNavigation: navigation != nil)
    }

    /// Web コンテンツのプロセスがクラッシュした場合、現在位置で開き直す。
    /// 終了が繰り返される場合は、再試行回数を制限し、バックオフを行う。
    ///
    /// Reopens at the current position if the web content process crashes,
    /// with bounded retry and backoff for repeated terminations.
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // cooViewer-oxr.47: 再構築前の WebView から遅配された終了通知で、
        // 現在の再試行枠を消費したり新しい文書を再読込しない。
        guard webView === self.webView else { return }
        handleWebContentProcessTermination()
    }

    /// cooViewer-oxr.47: 時刻注入可能な本体を分け、60 秒窓を sleep なしで検証する。
    func handleWebContentProcessTermination(at now: Date = Date()) {
        spineNavigationGate.abandonForProcessTermination()
        // プロセスと一緒に前の文書も失われるため、通常の読み込み失敗の復旧先にしない。
        spineLoad.resetRecovery()
        switch webContentReload.limiter.register(
            spineIndex: currentSpineIndex, at: now) {
        case .reload(let delay):
            webContentReload.requestCount += 1
            scheduleWebContentReload(after: delay)
        case .suppress(let reportFailure):
            cancelPendingWebContentReload()
            if spineLoad.isLoadingSpineItem {
                abandonSpineLoad()
                refreshFurnitureAfterAbandon()
            }
            if reportFailure {
                delegate?.readerView(
                    self,
                    didFailWith: EPUBError.malformed(
                        "web content process terminated repeatedly"))
            }
        }
    }

    /// 予約・保留中の再読み込みを取り消す(本の差し替え、別 spine への移動、抑止)
    func cancelPendingWebContentReload() {
        webContentReload.task?.cancel()
        webContentReload.task = nil
        webContentReload.pendingDelay = nil
    }

    private func scheduleWebContentReload(after delay: Duration) {
        webContentReload.task?.cancel()
        webContentReload.task = nil
        guard allowsVisibleRenderingWork else {
            // cooViewer-oxr.47: 不可視中は同じ再試行を保持し、表示復帰で消費する。
            webContentReload.pendingDelay = delay
            return
        }
        webContentReload.pendingDelay = nil
        guard delay != .zero else {
            performWebContentReload()
            return
        }
        webContentReload.task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.webContentReload.task = nil
            guard self.allowsVisibleRenderingWork else {
                self.webContentReload.pendingDelay = .zero
                return
            }
            self.performWebContentReload()
        }
    }

    func resumePendingWebContentReloadIfNeeded() {
        guard let delay = webContentReload.pendingDelay,
              allowsVisibleRenderingWork else { return }
        scheduleWebContentReload(after: delay)
    }

    private func performWebContentReload() {
        guard publication != nil else { return }
        webContentReload.attemptCount += 1
        reloadCurrentPublication()
    }

    /// ポップアップを開くことを許可しない。
    ///
    /// Does not allow popups to open.
    public func webView(_ webView: WKWebView,
                        createWebViewWith configuration: WKWebViewConfiguration,
                        for navigationAction: WKNavigationAction,
                        windowFeatures: WKWindowFeatures) -> WKWebView? {
        nil
    }
}
