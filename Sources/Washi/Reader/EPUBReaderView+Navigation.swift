import AppKit

/// EPUBReaderView のナビゲーション API: 読書位置(locator)、前後・目次・
/// 印刷ページ・巻頭巻末への移動、target の適用と移動履歴。
extension EPUBReaderView {
    // MARK: - ナビゲーション API

    /// 本の実効的な綴じ方向が右から左かどうか。
    ///
    /// Whether the book's effective reading direction is right-to-left.
    public var isRTL: Bool {
        publication?.effectiveReadingDirection == .rtl
    }

    /// 出版物が要求するフロー(`rendition:flow`)と、ひと続きのスクロールを
    /// 求めているかどうか(`rendition:layout="roll"`、または `roll` の登場前に
    /// 日本の出版社が使っていた `pre-paginated` + `scrolled-continuous`
    /// の組み合わせ)。
    ///
    /// The flow the publication asks for (`rendition:flow`), and whether it
    /// wants one continuous scroll (`rendition:layout="roll"`, or the
    /// `pre-paginated` + `scrolled-continuous` pair Japanese publishers used
    /// before `roll` existed).
    ///
    /// リーダーは項目ごとの上書きを反映し、scrolled-doc は章単位、
    /// scrolled-continuous は連続する章をつないでスクロール表示する。
    /// このプロパティは上書き前の出版物全体の宣言を返す。
    ///
    /// The reader honors item overrides, scrolling individual chapters for
    /// scrolled-doc and joining consecutive chapters for scrolled-continuous.
    /// This property returns the publication-wide declaration before overrides.
    public var requestedFlow: RenditionFlow {
        publication?.package.metadata.rendition.flow ?? .auto
    }

    /// 出版物がひと続きのスクロール表示を求めているかどうか。
    ///
    /// Whether the publication asks to be shown as one continuous scroll.
    public var requestsContinuousScroll: Bool {
        publication?.package.isScrollLike ?? false
    }

    /// テキストの錨を付けた現在位置(cooViewer-oxr.46 C52)。
    /// `progression` だけでは復元時に再量子化されるため、文字サイズや
    /// ビューポートを変えると保存位置が数ページずれる。錨にはページ先頭の
    /// 文字を記録し、同じ文へ戻れるようにする。しおりや最終読書位置の
    /// 保存時に取得すること。Web ビューとのやり取りが 1 往復発生する。
    /// 画像や空ページなど、位置を解決できない場合は通常の locator を返す。
    ///
    /// The current position with a text anchor attached (cooViewer-oxr.46 C52).
    /// `progression` alone is re-quantized on restore, so a saved position
    /// drifts by a few pages after a font-size or viewport change; the anchor
    /// records which character is at the top of the page so the reader can land
    /// on the same sentence. Ask for it when persisting a position (bookmarks,
    /// last-read); it costs one round trip to the web view. Falls back to the
    /// plain locator when the position cannot be resolved (images, empty pages).
    public func currentLocatorWithTextAnchor() async -> EPUBLocator {
        var locator = currentLocator
        guard !spineLoad.isLoadingSpineItem, canRenderSpine(at: currentSpineIndex),
              let webView else { return locator }
        let result = try? await webView.callAsyncJavaScript(
            "return __washi.visibleTextOffset();",
            arguments: [:], in: nil, contentWorld: WashiContentWorld.world)
        if let offset = result as? Int, offset >= 0 {
            locator.textOffset = offset
        }
        return locator
    }

    public var currentLocator: EPUBLocator {
        // cooViewer-oxr.23: 読み込み中は旧文書由来のページカウンタでなく、
        // load/go が最後に予約した target を現在位置として答える。
        if spineLoad.isLoadingSpineItem {
            return locator(for: spineLoad.pendingTarget, at: currentSpineIndex)
        }
        // 復元がまだ適用されていない間は復元先を答える(開いてすぐ閉じたときに
        // 保存済み位置を (0,0) で潰さない)
        if let pendingRestoreLocator = spineLoad.pendingRestoreLocator {
            return pendingRestoreLocator
        }
        let progression = scrollProgression ?? (pageCountInItem <= 1
            ? 0 : Double(pageInItem) / Double(pageCountInItem - 1))
        return makeLocator(spineIndex: currentSpineIndex, progression: progression)
    }

    /// idref 併記(publication.resolve で改版追跡できる形)の locator。
    /// 本が無い(または spine 外)ときは index だけの locator
    func makeLocator(spineIndex: Int, progression: Double) -> EPUBLocator {
        publication?.locator(forSpineIndex: spineIndex, progression: progression)
            ?? EPUBLocator(spineIndex: spineIndex, progression: progression)
    }

    /// 読書順に進む(項目内の次ページ → 次の spine 項目)。
    /// リフローコンテンツの項目内移動の判断は JS (turnInDoc) に任せる。
    /// ネイティブ側のページカウンタは非同期で更新されるため、それに頼ると
    /// 高速なキーリピートで競合し、章全体を飛ばしてしまう。
    ///
    /// Advances in reading order (next page within the item → next spine item).
    /// The within-item decision for reflowable content is left to JS (turnInDoc):
    /// the native page counter is updated asynchronously, so relying on it would
    /// race under rapid key-repeat and skip whole chapters.
    public func goForward() { turnInDocAnimated(forward: true) }

    /// 読書順に戻る。
    ///
    /// Goes back in reading order.
    public func goBackward() { turnInDocAnimated(forward: false) }

    /// 物理的な方向でページをめくる(右から左へ読む本では「左」が前進)。
    ///
    /// Page turn by physical direction (in a right-to-left book, "left" = forward).
    public func turnPageLeft() { isRTL ? goForward() : goBackward() }
    public func turnPageRight() { isRTL ? goBackward() : goForward() }

    public func go(to locator: EPUBLocator) {
        navigate(to: locator, recordsHistory: true)
    }

    /// 最後に記録したジャンプ元へ移動する。移動履歴がない場合は何もしない。
    /// 表示できない項目の履歴は取り除き、読み込みの失敗を通知する。
    ///
    /// Navigates to the most recently recorded jump origin. Does nothing when
    /// no navigation history is available. An entry that cannot be displayed
    /// is removed from the history and the load failure is reported.
    public func goBack() {
        // 通知から再び goBack されても、同じ項目を二度取り出さない。
        guard let locator = navigationHistory.popLast() else { return }
        if let resolved = publication?.resolve(locator),
           webView?.url != nil, let failure = spineLoadFailure(at: resolved.spineIndex) {
            updateCanGoBack()
            reportRejectedNavigation(failure)
            return
        }
        // cooViewer-oxr.31: 戻る移動そのものは新しい履歴として積まない。
        navigate(to: locator, recordsHistory: false)
        updateCanGoBack()
    }

    // 移動の入口は 5 つ: navigate(go(to:) と goBack)、go(to:textRange:)、
    // go(to navItem)、goToContainerPath の同一項目と別項目。骨格はどれも
    // 「拒否判定 → 要求世代を進める → 履歴に積む → 世代が同じなら適用か読み込み」で、
    // 共通化しないのは拒否と履歴の材料が違うため: navigate は idref で解決した先を
    // 拒否判定にかけ、go(to:textRange:) は delegate へ拒否を通知せず(描画不能なら nil)、
    // 継続を登録してから履歴に積む。go(to navItem) は fragment を拒否判定の後で解く。
    // goToContainerPath は同一項目でも拒否判定を通す(読み込みに失敗した項目に留まらない)。
    private func navigate(to locator: EPUBLocator, recordsHistory: Bool) {
        guard let publication,
              // cooViewer-oxr.72: idref があれば index より優先して改版追跡する。
              let resolved = publication.resolve(locator) else { return }
        guard !rejectsUnloadableNavigation(to: resolved.spineIndex) else { return }
        cancelPendingTextRangeRequest()
        let request = beginNavigationRequest()
        // cooViewer-oxr.46 C52: テキストアンカーがあれば、進行率の再量子化で
        // 数ページずれる代わりに、保存したときと同じ文へ厳密に着地させる。
        // 見つからなければ進行率へ落ちる(textRange の fallback がその役目)。
        let target: PendingTarget
        if let textOffset = resolved.textOffset {
            target = .textRange(utf16Offset: textOffset, utf16Length: 1,
                                fallbackProgression: resolved.progression)
        } else {
            target = .progression(resolved.progression)
        }
        if recordsHistory { recordCurrentLocatorInHistory() }
        guard request == navigationRequestGeneration else { return }
        if resolved.spineIndex == currentSpineIndex {
            applyOrQueueTarget(target)
        } else {
            loadSpineItem(at: resolved.spineIndex, target: target)
        }
    }

    /// 目次項目へ移動する。
    ///
    /// Navigates to a table-of-contents item.
    public func go(to navItem: EPUBNavItem) {
        guard let publication,
              let index = publication.spineIndex(forNavItem: navItem) else { return }
        guard !rejectsUnloadableNavigation(to: index) else { return }
        let request = beginNavigationRequest()
        let fragment = navItem.href.flatMap(Self.fragment(of:))
        let target: PendingTarget = fragment.map { .fragment($0) } ?? .start
        recordCurrentLocatorInHistory()
        guard request == navigationRequestGeneration else { return }
        if index == currentSpineIndex {
            applyOrQueueTarget(target)
        } else {
            loadSpineItem(at: index, target: target)
        }
    }

    /// 解決済みの内部リンクを、リーダーの既定の移動方法でたどる。
    ///
    /// Follows a resolved internal link using the reader's default navigation.
    ///
    /// delegate の内部リンクポリシーのコールバックを経由せず、移動前に
    /// 現在の locator を移動履歴へ記録する。リンクを捕捉した後、ホストが
    /// 改めて移動すると決めたときに使う。
    ///
    /// This method bypasses the delegate's internal-link policy callback and
    /// records the current locator in navigation history before moving. Use it
    /// after intercepting a link when the host later decides to navigate.
    public func follow(_ link: EPUBInternalLink) {
        goToContainerPath(link.containerPath, fragment: link.fragment)
    }

    /// 出版物のページリストで宣言された印刷ページのラベルへ移動する。
    /// 一致するラベルのうち、移動先を解決できるものがなければ false を返す。
    /// 表示できない項目への移動を拒否した場合も false を返す。
    ///
    /// Navigates to a print page label declared by the publication's page
    /// list. Returns false when no resolvable matching label exists.
    /// Also returns false when navigation to an unloadable item is rejected.
    @discardableResult
    public func go(toPrintPage label: String) -> Bool {
        guard let publication,
              let item = flattenedPrintPageList.first(where: {
                  $0.title == label && publication.spineIndex(forNavItem: $0) != nil
              }),
              let index = publication.spineIndex(forNavItem: item) else { return false }
        guard !rejectsUnloadableNavigation(to: index) else { return false }
        // cooViewer-oxr.38: TOC と同じ go(navItem:) を通し、oxr.31 の
        // 履歴記録・fragment 解決・spine 切替を二重実装しない。
        go(to: item)
        return true
    }

    var flattenedPrintPageList: [EPUBNavItem] {
        func flatten(_ items: [EPUBNavItem]) -> [EPUBNavItem] {
            items.flatMap { [$0] + flatten($0.children) }
        }
        return flatten(publication?.navigation.pageList ?? [])
    }

    public func goToBookStart() {
        guard !rejectsUnloadableNavigation(to: 0) else { return }
        _ = beginNavigationRequest()
        loadSpineItem(at: 0, target: .start)
    }

    public func goToBookEnd() {
        guard let publication else { return }
        guard !rejectsUnloadableNavigation(to: publication.readingOrder.count - 1) else { return }
        _ = beginNavigationRequest()
        loadSpineItem(at: publication.readingOrder.count - 1, target: .end)
    }

    func advanceSpine(forward: Bool) {
        guard let publication else { return }
        var next: Int
        if let group = loadedScrollGroup {
            next = forward ? group.upperBound : group.lowerBound - 1
        } else {
            next = currentSpineIndex + (forward ? 1 : -1)
        }
        // 指定先のないページ送りでは、拒否と同じ判定で表示不能な項目を飛ばす。
        while publication.readingOrder.indices.contains(next), spineLoadFailure(at: next) != nil {
            next += forward ? 1 : -1
        }
        guard publication.readingOrder.indices.contains(next) else {
            // 巻頭/巻末超え: ホストの反応(ループ・隣の本・何もしない)は
            // めくり演出ではないので、演出の持ち越しカバーは先に畳む。
            // 控えのカバーは、読み込み中の最後の項目の表示が戻るまで残す(Washi-3b1)
            if turn.pendingSpineTurn?.animated != false { clearPendingSpineTurn() }
            delegate?.readerView(self, didReachBookEdge: forward)
            return
        }
        loadSpineItem(at: next, target: forward ? .start : .end,
                      preservingTurnCover: true)
    }

    func applyTarget(_ target: PendingTarget) {
        switch target {
        case .start:
            cancelPendingTextRangeRequest()
            evaluate("__washi.showPage(0);")
        case .end:
            cancelPendingTextRangeRequest()
            evaluate("__washi.showLastPage();")
        case .progression(let progression):
            cancelPendingTextRangeRequest()
            // cooViewer-oxr.73: 呼び出し境界でも有限な 0...1 に丸め、
            // 旧保存形式や外部からの異常値を JavaScript へ渡さない。
            let safeProgression = Self.clampedProgression(progression)
            evaluate("__washi.showProgression(\(safeProgression));")
        case .fragment(let fragment):
            cancelPendingTextRangeRequest()
            // 断片 id は EPUB 由来(信頼できない)。文字列連結でなく引数渡しで
            // WebKit に完全エスケープさせる(手動 \\・' では改行・行区切りを取りこぼす)
            callWashiDetached("return __washi.showFragment(id);",
                              arguments: ["id": fragment])
        case .textRange(let utf16Offset, let utf16Length, let fallbackProgression):
            // go(locator:) / goBack() は継続を持たないが、保存したアンカーは
            // 同じように解決する。実際に見つからなかったときだけ進行率へ戻す。
            let requestID = pendingTextRangeRequest?.id
            textRangeTask?.cancel()
            textRangeTask = Task { @MainActor [weak self] in
                guard let self, !Task.isCancelled else { return }
                let landing = await self.locateTextRange(
                    utf16Offset: utf16Offset, utf16Length: utf16Length)
                guard !Task.isCancelled else { return }
                if landing == nil {
                    let safeProgression = Self.clampedProgression(fallbackProgression)
                    self.evaluate("__washi.showProgression(\(safeProgression));")
                }
                if let requestID {
                    self.finishTextRangeRequest(id: requestID, landing: landing)
                } else {
                    self.textRangeTask = nil
                }
            }
        }
    }

    /// cooViewer-oxr.19: spine 読み込み中の同一項目ナビゲーションは旧 DOM へ
    /// 適用せず、進行中の setup が最後の target を一度だけ消費する。
    func applyOrQueueTarget(_ target: PendingTarget) {
        let isTextRange: Bool
        if case .textRange = target {
            isTextRange = true
        } else {
            isTextRange = false
        }
        guard spineLoad.isLoadingSpineItem else {
            if isTextRange {
                // 着地前の保存・戻る履歴にもアンカーを残し、進行率だけへ劣化させない。
                spineLoad.pendingRestoreLocator = locator(for: target, at: currentSpineIndex)
            }
            applyTarget(target)
            return
        }
        // textRange の継続は setup 後の exact landing が完了させるので取り消さない。
        if !isTextRange {
            cancelPendingTextRangeRequest()
        }
        spineLoad.pendingTarget = target
        // 読み込み中は復元先も差し替える(textRange のアンカーもここで残る)。
        spineLoad.pendingRestoreLocator = locator(for: target, at: currentSpineIndex)
    }

    func locator(for target: PendingTarget, at index: Int) -> EPUBLocator {
        let progression = progression(for: target)
        var locator = makeLocator(spineIndex: index, progression: progression)
        if case .textRange(let offset, _, _) = target { locator.textOffset = offset }
        return locator
    }

    private func progression(for target: PendingTarget) -> Double {
        switch target {
        case .end:
            return 1
        case .progression(let progression):
            return Self.clampedProgression(progression)
        case .textRange(_, _, let fallbackProgression):
            return Self.clampedProgression(fallbackProgression)
        case .start, .fragment:
            return 0
        }
    }

    /// コンテナ内パスへの移動(リンクの共通経路)。必ず loadSpineItem を
    /// 経由して currentSpineIndex を保つ — WKWebView に直接遷移させると
    /// 柱・ページバー・読書位置の保存がすべて旧 spine 項目のまま狂う
    func goToContainerPath(_ path: String, fragment: String?,
                           recordsHistory: Bool = true) {
        guard let publication,
              publication.readingOrder.indices.contains(currentSpineIndex)
        else { return }
        let current = publication.readingOrder[currentSpineIndex]
        if path == current.containerPath || path == current.resolvedContainerPath {
            guard !rejectsUnloadableNavigation(to: currentSpineIndex) else { return }
            let request = beginNavigationRequest()
            if recordsHistory { recordCurrentLocatorInHistory() }
            guard request == navigationRequestGeneration else { return }
            applyOrQueueTarget(fragment.map { .fragment($0) } ?? .start)
            return
        }
        guard let index = publication.readingOrder
            .firstIndex(where: {
                $0.containerPath == path || $0.resolvedContainerPath == path
            }) else { return }
        guard !rejectsUnloadableNavigation(to: index) else { return }
        let request = beginNavigationRequest()
        if recordsHistory { recordCurrentLocatorInHistory() }
        guard request == navigationRequestGeneration else { return }
        loadSpineItem(at: index, target: fragment.map { .fragment($0) } ?? .start)
    }

    /// cooViewer-oxr.31: 移動直前の locator を最大 50 件に丸め、利用可否が
    /// 変わったときだけ delegate へ通知する。
    func recordCurrentLocatorInHistory() {
        if navigationHistory.count >= Self.navigationHistoryLimit {
            navigationHistory.removeFirst()
        }
        navigationHistory.append(currentLocator)
        updateCanGoBack()
    }

    func clearNavigationHistory() {
        navigationHistory.removeAll(keepingCapacity: true)
        updateCanGoBack()
    }

    private func updateCanGoBack() {
        let updated = !navigationHistory.isEmpty
        guard updated != canGoBack else { return }
        canGoBack = updated
        delegate?.readerViewNavigationHistoryDidChange(self)
    }
}
