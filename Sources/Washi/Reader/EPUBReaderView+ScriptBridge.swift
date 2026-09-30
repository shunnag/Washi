import AppKit
import WebKit

/// EPUBReaderView と washi ワールドの JS との橋渡し: スクリプトの評価と
/// 引数付き呼び出し、完了待ち、JS から届くメッセージの処理。
extension EPUBReaderView {
    /// washi world で `script` の完了を待つ。取り消されたらすぐに戻る。
    ///
    /// async 版の callAsyncJavaScript は取り消しに応じず、rAF が進まない間
    /// (最小化・遮蔽・ビューの取り外し)は ``race`` が打ち切った後も WKWebView を
    /// 保持し続ける。応答側が弱参照だけを持つ waitForOffscreenResult で待ち、
    /// 取り消されたら WebView を手放す。60 秒は取り消されなかった場合の保険
    static func waitForWashiScript(_ script: String, in webView: WKWebView) async {
        let _: Bool? = await waitForOffscreenResult(timeout: .seconds(60)) { completion in
            webView.callAsyncJavaScript(
                script, arguments: [:], in: nil, in: WashiContentWorld.world) { _ in
                    completion(true)
                }
        }
    }

    /// washi world で式を評価して結果を受け取る(内部・テスト共用)。
    /// 拡張側からは webView が見えないのでここに置く。
    func callWashiReturning(_ body: String,
                            arguments: [String: Any] = [:]) async -> Any? {
        guard let webView else { return nil }
        return try? await webView.callAsyncJavaScript(
            body, arguments: arguments, in: nil, contentWorld: WashiContentWorld.world)
    }

    func evaluate(_ script: String) {
        if let scriptEvaluationHandler {
            scriptEvaluationHandler(script)
            return
        }
        webView?.evaluateJavaScript(script, in: nil, in: WashiContentWorld.world)
    }

    /// washi ワールドで JS を評価する(メディアオーバーレイ拡張から使う)
    func evaluateWashi(_ script: String) { evaluate(script) }

    /// washi ワールドで JS を引数付きで呼ぶ(値は WebKit が完全にエスケープ
    /// するので、EPUB 由来の断片 id・クラス名を文字列連結で埋め込まない)。
    /// 表示中の webView への呼び出しなので QoS 逆転(オフスクリーン初回)には
    /// 該当しない
    func callWashiAsync(_ body: String, arguments: [String: Any]) {
        guard let webView else { return }
        Task { @MainActor in
            _ = await callWashiAsync(body, arguments: arguments, in: webView)
        }
    }

    /// washi ワールドへ JS を引数付きで即時に送り、応答は待たない。
    /// Task を挟まず、後から送る控えの撮り直しの描画待ちより先に実行する。
    func sendWashiNow(_ body: String, arguments: [String: Any]) {
        webView?.callAsyncJavaScript(body, arguments: arguments, in: nil,
                                     in: WashiContentWorld.world, completionHandler: nil)
    }

    func callWashiAsync(
        _ body: String, arguments: [String: Any], in webView: WKWebView
    ) async -> Any? {
        try? await webView.callAsyncJavaScript(
            body, arguments: arguments, in: nil, contentWorld: WashiContentWorld.world)
    }

    // MARK: - JS からのメッセージ

    func handleScriptMessage(_ body: Any) {
        guard let dict = body as? [String: Any],
              let type = dict["type"] as? String,
              isFromCurrentDocument(dict) else { return }
        if let index = dict["spineIndex"] as? Int {
            guard !isLoadingSpineItem, isFromCurrentDocument(dict),
                  loadedScrollGroup?.contains(index) == true else { return }
        }
        switch type {
        case "scrollFailure":
            guard loadedScrollGroup != nil else { break }
            delegate?.readerView(self, didFailWith: EPUBError.malformed(
                dict["reason"] as? String ?? "Cannot load continuous chapter"))
        case "pageChanged":
            // cooViewer-oxr.19/23: 旧文書から遅配された位置通知で、新しい
            // pending target / 復元位置とホストの保存位置を上書きしない。
            // cooViewer-oxr.46 C35: 読み込みが済んだ後に届く旧文書の通知も、
            // setup で渡した印が違うので同じく捨てる。
            guard !isLoadingSpineItem, isFromCurrentDocument(dict) else { break }
            let request = navigationRequestGeneration
            let generation = spineLoadGeneration
            if let index = dict["spineIndex"] as? Int, index != currentSpineIndex {
                currentSpineIndex = index
                setCurrentSelection(nil)
                guard request == navigationRequestGeneration,
                      generation == spineLoadGeneration else { break }
                applyHighlights()
            }
            if dict["printPageMarkers"] != nil { applySetupResult(dict) }
            pageInItem = dict["page"] as? Int ?? 0
            pageCountInItem = max(1, dict["pageCount"] as? Int ?? 1)
            scrollProgression = (dict["progression"] as? Double).map(Self.clampedProgression)
            pagesPerScreen = max(1, dict["pagesPerScreen"] as? Int ?? pagesPerScreen)
            pendingRestoreLocator = nil  // 実位置が確定した
            updateCurrentPrintPage()
            guard request == navigationRequestGeneration,
                  generation == spineLoadGeneration else { break }
            updateFurniture()
            delegate?.readerView(self, didMoveTo: currentLocator,
                                 pageInItem: pageInItem,
                                 pageCountInItem: pageCountInItem)
            guard request == navigationRequestGeneration,
                  generation == spineLoadGeneration else { break }
            scheduleAccessibilityPageAnnouncement()
            // ページが変わったので控えを撮り直す
            schedulePageCoverPrefetch()
        case "boundary":
            // spine 切替の読み込み中に旧文書から届く境界イベントは捨てる
            // (トラックパッド慣性やキーリピートでの章飛び越し防止)
            guard !isLoadingSpineItem else { break }
            let forward = dict["forward"] as? Bool ?? true
            advanceSpine(forward: forward)
        case "wheelTurn":
            // ホイール/トラックパッドの 1 ジェスチャ 1 ページ(JS でラッチ済み)。
            // native 経由にするのはスライド演出を共通で付けるため。
            // spine 読み込み中の残存慣性は boundary と同じく捨てる(FXL 項目が
            // 表示される前に advanceSpine で飛ばされるカスケードを防ぐ)。
            // 水平ジェスチャは物理方向(deltaX>0=右側のページ)として受け、
            // 綴じ方向への変換はタップと同じく turnPageLeft/Right が担う
            // (JS は表紙等の画像ページで本の writing-mode を知れない)。
            // 垂直ジェスチャは内部縦積みと一致するので下=読書順で次
            guard !isLoadingSpineItem else { break }
            let forward = dict["forward"] as? Bool ?? true
            if dict["horizontal"] as? Bool ?? false {
                // native 経路と同じくホスト設定でゲート・反転する
                guard settings.horizontalWheelTurnsPages else { break }
                let towardRight = forward != settings.reversesHorizontalWheelTurn
                towardRight ? turnPageRight() : turnPageLeft()
            } else {
                forward ? goForward() : goBackward()
            }
        case "link":
            handleLink(dict)
        case "tap":
            // DOM のボタン番号(0=左,1=中,2=右,3/4=サイド)→ NSEvent 流
            // (0=左,1=右,2=中,3/4=サイド)へ写像。右は JS 側で除外済み
            let domButton = dict["button"] as? Int ?? 0
            let button = domButton == 1 ? 2 : (domButton == 2 ? 1 : domButton)
            let normalizedX = dict["x"] as? Double ?? 0.5
            let normalizedY = dict["y"] as? Double ?? 0.5
            let location = webView.map {
                readerViewPoint(forNormalizedContentX: normalizedX,
                                y: normalizedY, in: $0)
            } ?? CGPoint(x: bounds.midX, y: bounds.midY)
            let event = EPUBClickEvent(
                x: normalizedX,
                y: normalizedY,
                locationInView: location,
                button: button,
                shift: dict["shift"] as? Bool ?? false,
                option: dict["alt"] as? Bool ?? false,
                control: dict["ctrl"] as? Bool ?? false,
                command: dict["meta"] as? Bool ?? false)
            dispatchClick(event)
        case "selection":
            guard !isLoadingSpineItem else { break }
            guard let text = dict["text"] as? String, !text.isEmpty,
                  let start = dict["start"] as? Int,
                  let end = dict["end"] as? Int,
                  start >= 0, end > start,
                  let rawRects = dict["rects"] as? [[String: Any]],
                  let webView else {
                setCurrentSelection(nil)
                break
            }
            let rects = rawRects.compactMap {
                readerViewRect(from: $0, in: webView)
            }
            guard rects.count == rawRects.count else {
                setCurrentSelection(nil)
                break
            }
            setCurrentSelection(EPUBTextSelection(
                spineIndex: currentSpineIndex, text: text,
                utf16Range: start..<end, rects: rects))
        case "key":
            let event = EPUBKeyEvent(
                key: dict["key"] as? String ?? "",
                code: dict["code"] as? String ?? "",
                shift: dict["shift"] as? Bool ?? false,
                option: dict["alt"] as? Bool ?? false,
                control: dict["ctrl"] as? Bool ?? false,
                command: dict["meta"] as? Bool ?? false)
            delegate?.readerView(self, didReceiveKey: event)
        default:
            break
        }
    }
}
