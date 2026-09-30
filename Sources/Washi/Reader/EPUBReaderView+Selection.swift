import AppKit
import WebKit

/// EPUBReaderView のテキスト範囲と選択: ハイライトの描画、UTF-16 範囲への
/// 正確な移動と矩形の取得、DOM 選択の反映と解除、範囲要求の完了・取消。
extension EPUBReaderView {
    func highlightsOnCurrentItem(_ list: [EPUBHighlight]) -> [EPUBHighlight] {
        let idref = publication?.readingOrder.indices.contains(currentSpineIndex) == true
            ? publication?.readingOrder[currentSpineIndex].itemRef.idref : nil
        return list.filter { $0.spineIndex == currentSpineIndex
            || ($0.idref != nil && $0.idref == idref) }
    }

    /// 現在表示している項目のハイライトを描画する。ハイライトの変更時と、
    /// spine の読み込み・再ページ割りの完了後に呼び出す。
    func applyHighlights() {
        guard webView != nil, !spineLoad.isLoadingSpineItem else { return }
        let payload = highlightsOnCurrentItem(highlights)
            .map { ["offset": $0.utf16Offset, "length": $0.utf16Length,
                    "style": $0.style.rawValue] as [String: Any] }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        evaluate("__washi.setHighlights(\(json));")
    }

    /// リフローまたは roll の spine 項目内で、指定した UTF-16 テキスト範囲へ
    /// 正確に移動する。
    ///
    /// Navigates to an exact UTF-16 text range in a reflowable or roll spine item.
    ///
    /// 返す矩形は、このリーダービューの座標系で表す。locator または
    /// 範囲を解決できない場合は `nil` を返すので、呼び出し側は進行率に
    /// 基づく移動へ切り替えられる。
    ///
    /// The returned rectangles are expressed in this reader view's coordinate
    /// system. Returns `nil` when the locator or range cannot be resolved, so
    /// callers can fall back to progression-based navigation.
    ///
    /// - Parameters:
    ///   - locator: 抽出本文の範囲を含む spine 項目。
    ///     The spine item containing the extracted-text range.
    ///   - textRange: その項目の抽出されたプレーンテキストにおける、
    ///     UTF-16 コード単位でのオフセットと長さ。
    ///     The offset and length in UTF-16 code units of that item's
    ///     extracted plain text.
    /// - Returns: DOM 上の正確な到達位置。
    ///   正確に位置を合わせられない場合は `nil`。
    ///   The exact DOM landing, or `nil` if exact positioning fails.
    public func go(
        to locator: EPUBLocator,
        textRange: (utf16Offset: Int, utf16Length: Int)
    ) async -> EPUBTextRangeLanding? {
        guard let publication,
              let locator = publication.resolve(locator),
              textRange.utf16Offset >= 0, textRange.utf16Length > 0,
              textRange.utf16Offset <= Int.max - textRange.utf16Length,
              canRenderSpine(at: locator.spineIndex),
              (publication.package.effectiveLayout(
                for: publication.readingOrder[locator.spineIndex].itemRef)
                != .prePaginated
                || publication.renderingFlow(at: locator.spineIndex) == .scrolledContinuous)
        else { return nil }

        let request = beginNavigationRequest()
        let requestID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                cancelPendingTextRangeRequest()
                pendingTextRangeRequest = PendingTextRangeRequest(
                    id: requestID, continuation: continuation)
                let target = PendingTarget.textRange(
                    utf16Offset: textRange.utf16Offset,
                    utf16Length: textRange.utf16Length,
                    fallbackProgression: locator.progression)
                recordCurrentLocatorInHistory()
                guard request == navigationRequestGeneration else {
                    cancelPendingTextRangeRequest(id: requestID)
                    return
                }
                if locator.spineIndex == currentSpineIndex {
                    applyOrQueueTarget(target)
                } else {
                    loadSpineItem(at: locator.spineIndex, target: target)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelPendingTextRangeRequest(id: requestID)
            }
        }
    }

    func locateTextRange(
        utf16Offset: Int, utf16Length: Int
    ) async -> EPUBTextRangeLanding? {
        if let textRangeLocationHandler {
            return await textRangeLocationHandler(utf16Offset, utf16Length)
        }
        guard let webView else { return nil }
        let result = await callWashiAsync(
            "return __washi.locateAndShow(o, l);",
            arguments: ["o": utf16Offset, "l": utf16Length], in: webView)
        guard webView === self.webView,
              let dictionary = result as? [String: Any],
              dictionary["found"] as? Bool == true,
              let page = dictionary["page"] as? Int,
              let text = dictionary["text"] as? String,
              let rawRects = dictionary["rects"] as? [[String: Any]]
        else { return nil }

        let rects = rawRects.compactMap {
            readerViewRect(from: $0, in: webView)
        }
        // 空矩形は「特定できなかった」扱い(JS 側も null を返すが多重防御。cooViewer-cvt)
        guard rects.count == rawRects.count, !rects.isEmpty else { return nil }
        return EPUBTextRangeLanding(pageInItem: page, text: text, rects: rects)
    }

    /// 現在の DOM 選択を解除し、選択状態が nil になったことを直ちに通知する。
    ///
    /// Clears the current DOM selection and immediately publishes a nil
    /// selection state.
    public func clearSelection() {
        let request = navigationRequestGeneration
        setCurrentSelection(nil)
        guard request == navigationRequestGeneration else { return }
        callWashiAsync("return __washi.clearSelection();", arguments: [:])
    }

    /// 現在読み込まれている spine 項目内で、正規化済みの UTF-16 テキスト
    /// 範囲のうち可視部分の矩形を返す。別の spine 項目には空配列を返し、
    /// 副作用としてその項目を読み込むことはない。
    ///
    /// Returns the visible fragments for a normalized UTF-16 text range in
    /// the currently loaded spine item. Other spine items return an empty
    /// array and are not loaded as a side effect.
    public func rects(
        forTextRange range: Range<Int>, inSpineIndex index: Int
    ) async -> [CGRect] {
        guard index == currentSpineIndex, !spineLoad.isLoadingSpineItem,
              canRenderSpine(at: index),
              !isFixedLayoutItem, range.lowerBound >= 0, !range.isEmpty,
              let webView else { return [] }
        let result = await callWashiAsync(
            "return __washi.rectsForTextRange(o, l);",
            arguments: ["o": range.lowerBound, "l": range.count], in: webView)
        guard webView === self.webView,
              let rawRects = result as? [[String: Any]] else { return [] }
        return rawRects.compactMap { readerViewRect(from: $0, in: webView) }
    }

    /// cooViewer-oxr.34: 同値通知を畳み、clearSelection の即時 nil と JS の
    /// selectionchange 遅配が delegate へ二重に届かないようにする。
    func setCurrentSelection(_ selection: EPUBTextSelection?) {
        guard selection != currentSelection else { return }
        currentSelection = selection
        delegate?.readerView(self, selectionDidChange: selection)
    }

    /// cooViewer-oxr.32: DOMRect(左上原点)を現在 WKWebView の実座標系へ直し、
    /// AppKit に inset と reader-view 座標への変換を任せる。
    func readerViewRect(
        from raw: [String: Any], in webView: WKWebView
    ) -> CGRect? {
        guard let x = Self.number(raw["x"]),
              let y = Self.number(raw["y"]),
              let width = Self.number(raw["w"]),
              let height = Self.number(raw["h"]),
              x.isFinite, y.isFinite, width.isFinite, height.isFinite,
              width >= 0, height >= 0
        else { return nil }
        let localY = webView.isFlipped
            ? CGFloat(y)
            : webView.bounds.height - CGFloat(y) - CGFloat(height)
        let local = CGRect(x: CGFloat(x), y: localY,
                           width: CGFloat(width), height: CGFloat(height))
        return webView.convert(local, to: self)
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        return value as? Double
    }

    func finishTextRangeRequest(
        id: UUID, landing: EPUBTextRangeLanding?
    ) {
        guard pendingTextRangeRequest?.id == id else { return }
        let continuation = pendingTextRangeRequest?.continuation
        pendingTextRangeRequest = nil
        textRangeTask = nil
        continuation?.resume(returning: landing)
    }

    func cancelPendingTextRangeRequest(id: UUID? = nil) {
        if let id, pendingTextRangeRequest?.id != id { return }
        textRangeTask?.cancel()
        textRangeTask = nil
        let continuation = pendingTextRangeRequest?.continuation
        pendingTextRangeRequest = nil
        continuation?.resume(returning: nil)
    }
}
