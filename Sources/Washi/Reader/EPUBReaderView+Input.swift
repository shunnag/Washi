import AppKit
import WebKit

/// EPUBReaderView のネイティブ入力: キー配送とネイティブキー横取り、ピンチ、
/// ドラッグ&ドロップ、コンテキストメニュー、余白のクリックとホイール。
extension EPUBReaderView {
    /// キーボードフォーカスを受け付ける(ホストからのキーバインド転送と、
    /// モード切り替え時の `makeFirstResponder` の対象)。
    ///
    /// Accepts keyboard focus (the landing point for the host's key-binding
    /// forwarding and for `makeFirstResponder` on mode switches).
    public override var acceptsFirstResponder: Bool { true }

    /// コンテナが受け取ったキーを、Web ビューと共通のキーボード設定の
    /// 規則に従って処理する。
    ///
    /// Routes a key received by the container through the same keyboard
    /// settings contract used by its web view.
    public override func keyDown(with event: NSEvent) {
        routeKeyDown(with: event) { event in
            if let webView {
                webView.keyDown(with: event)
            } else {
                super.keyDown(with: event)
            }
        }
    }

    // WebKit への配送を分離し、プロセス間通信に依存せず再入経路を検証する。
    func routeKeyDown(with event: NSEvent, forward: (NSEvent) -> Void) {
        // Washi #3: WebKit が未処理キーを super.keyDown 経由で返すと
        // このコンテナへ戻る。転送中の再入は上位 responder へ通し、往復を断つ。
        guard !isRoutingKeyDown,
              (webView as? WashiWebView)?.isHandlingKeyDown != true else {
            super.keyDown(with: event)
            return
        }
        isRoutingKeyDown = true
        defer { isRoutingKeyDown = false }
        // cooViewer-oxr.80: コンテナが responder の場合もキーを取りこぼさない。
        guard !settings.handlesKeyboardNavigation else {
            forward(event)
            return
        }
        let modifiers = event.modifierFlags
        let (key, code) = Self.webKeyIdentity(for: event)
        let forwarded = EPUBKeyEvent(
            key: key,
            code: code,
            shift: modifiers.contains(.shift),
            option: modifiers.contains(.option),
            control: modifiers.contains(.control),
            command: modifiers.contains(.command))
        delegate?.readerView(self, didReceiveKey: forwarded)
        // Washi #3: ホストが扱わなかったキーはここで消さず responder チェーンへ返す。
        // shouldConsumeKey の既定は true(delegate 未設定も同じ)で、false のときだけ
        // super.keyDown へ渡す。WebKit を経由しないため #3 の往復は起きない。
        if delegate?.readerView(self, shouldConsumeKey: forwarded) == false {
            super.keyDown(with: event)
        }
    }

    private static func webKeyIdentity(for event: NSEvent) -> (String, String) {
        switch event.keyCode {
        case 123: return ("ArrowLeft", "ArrowLeft")
        case 124: return ("ArrowRight", "ArrowRight")
        case 125: return ("ArrowDown", "ArrowDown")
        case 126: return ("ArrowUp", "ArrowUp")
        case 116: return ("PageUp", "PageUp")
        case 121: return ("PageDown", "PageDown")
        case 115: return ("Home", "Home")
        case 119: return ("End", "End")
        case 49: return (" ", "Space")
        default:
            let value = event.charactersIgnoringModifiers ?? event.characters ?? ""
            return (value, value)
        }
    }

    // MARK: - ピンチ(フォント倍率)

    /// フォント倍率に指定できる範囲。
    ///
    /// Allowed range for the font scale.
    public static let fontScaleRange: ClosedRange<Double> = 0.5...3.0

    /// ピンチ中は WKWebView.magnification で視覚追従だけ行い(再ページ割り
    /// なしで滑らか)、終了時に fontScale へ確定して進行率を保ったまま
    /// 再ページ割りする(テキストは再流し込みされるのでシャープなまま)
    @objc func handleMagnification(_ gesture: NSMagnificationGestureRecognizer) {
        guard settings.pinchAdjustsFontScale,
              !isFixedLayoutItem, let webView, publication != nil else { return }
        let base = pinchBaseFontScale ?? settings.fontScale
        // 確定可能な範囲に対応する視覚倍率へクランプ
        let target = min(Self.fontScaleRange.upperBound,
                         max(Self.fontScaleRange.lowerBound,
                             base * (1 + gesture.magnification)))
        let previewFactor = target / base
        switch gesture.state {
        case .began:
            pinchBaseFontScale = settings.fontScale
        case .changed:
            webView.setMagnification(previewFactor,
                                     centeredAt: gesture.location(in: webView))
        case .ended, .cancelled, .failed:
            webView.magnification = 1
            pinchBaseFontScale = nil
            guard abs(target - settings.fontScale) > 0.01 else { return }
            var updated = settings
            updated.fontScale = target
            settings = updated  // didSet → 進行率を保った再ページ割り
            delegate?.readerView(self, didChangeFontScale: target)
        default:
            break
        }
    }

    /// フォント倍率を指定量だけ増減する(キーバインドやメニュー用)。
    ///
    /// Steps the font scale up or down (for key bindings and menus).
    public func adjustFontScale(by delta: Double) {
        let target = min(Self.fontScaleRange.upperBound,
                         max(Self.fontScaleRange.lowerBound,
                             settings.fontScale + delta))
        guard abs(target - settings.fontScale) > 0.001 else { return }
        var updated = settings
        updated.fontScale = target
        settings = updated
        delegate?.readerView(self, didChangeFontScale: target)
    }

    // MARK: - ドラッグ&ドロップ(ホストへの委譲)

    public override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        .copy
    }

    public override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        dispatchDroppedURL(from: sender.draggingPasteboard)
    }

    func dispatchDroppedURL(from pasteboard: NSPasteboard) -> Bool {
        guard let url = NSURL(from: pasteboard) as URL? else {
            return false
        }
        return dispatchDroppedURL(url)
    }

    /// cooViewer-oxr.84: URL pasteboard 型に紛れたネットワーク URL は、
    /// ファイルを開く delegate 契約へ渡さない。
    func dispatchDroppedURL(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        return delegate?.readerView(self, didReceiveDroppedFileURL: url) ?? false
    }

    // MARK: - ネイティブキー横取り(forwardsKeyEventsNatively)

    /// ウインドウ在席と設定に応じてローカルキーモニタを付け外しする。
    /// WKWebView がファーストレスポンダを握るとビューの keyDown は呼ばれず
    /// JS 経路のキーも取りこぼすため、ホストが確実に NSEvent を受け取れるよう
    /// ウインドウレベルの local monitor で横取りする(cooViewer が自前で
    /// やっていた対処をパッケージ側の任意機能として提供)
    func updateNativeKeyMonitor() {
        let shouldMonitor = window != nil && settings.forwardsKeyEventsNatively
        if shouldMonitor, keyEventMonitor == nil {
            keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
                [weak self] event in
                guard let self else { return event }
                return self.handleNativeKeyEvent(event)
            }
        } else if !shouldMonitor, let monitor = keyEventMonitor {
            NSEvent.removeMonitor(monitor)
            keyEventMonitor = nil
        }
    }

    // モニタの実配送とテストで、フォーカス判定・同一イベントの重複排除を共有する。
    func handleNativeKeyEvent(_ event: NSEvent) -> NSEvent? {
        guard settings.forwardsKeyEventsNatively, event.type == .keyDown,
              let window, event.window === window, let delegate,
              !isHiddenOrHasHiddenAncestor, superview != nil else { return event }
        let focused = window.firstResponder
        let contentIsFocused = (focused as? NSView).map { focused in
            webView.map { focused === $0 || focused.isDescendant(of: $0) } ?? false
        } ?? false
        guard focused === self || contentIsFocused else { return event }

        if let consumed = nativeKeyResults.object(forKey: event) {
            return consumed.boolValue ? nil : event
        }
        // delegate が同じイベントを同期再送しても、処理中の一度目へ戻さない。
        nativeKeyResults.setObject(NSNumber(value: true), forKey: event)
        let consumed = delegate.readerView(self, didReceiveNativeKey: event)
        nativeKeyResults.setObject(NSNumber(value: consumed), forKey: event)
        return consumed ? nil : event
    }

    /// cooViewer-oxr.35: DOM の左上原点正規化座標を WebView の AppKit 座標へ
    /// 直し、余白入力と同じ reader-view 座標へ統一する。
    func readerViewPoint(
        forNormalizedContentX x: Double, y: Double, in webView: WKWebView
    ) -> CGPoint {
        let localY = webView.isFlipped
            ? CGFloat(y) * webView.bounds.height
            : (1 - CGFloat(y)) * webView.bounds.height
        let local = CGPoint(x: CGFloat(x) * webView.bounds.width, y: localY)
        return webView.convert(local, to: self)
    }

    private var effectiveContextMenuPolicy: EPUBContextMenuPolicy {
        if settings.contextMenuPolicy == .system && settings.suppressesContextMenu {
            return .suppressed
        }
        return settings.contextMenuPolicy
    }

    /// cooViewer-oxr.35, cooViewer-oxr.93: policy を先に適用し、空になっても
    /// 1 イベントにつき 1 回 delegate の最終カスタマイズへ渡す。
    /// イベント位置は tap/余白 click と同じ座標系。
    func contextMenu(_ menu: NSMenu, for event: NSEvent) -> NSMenu? {
        _ = effectiveContextMenuPolicy.filter(menu)
        let click = clickEvent(for: event, button: event.buttonNumber)
        guard let delegate else { return menu }
        guard let resolved = delegate.readerView(
            self, willShowContextMenu: menu, at: click) else {
            menu.removeAllItems()
            return nil
        }
        return resolved
    }

    /// クリックの共通ディスパッチ(JS の tap 通知と余白のネイティブクリック)
    func dispatchClick(_ event: EPUBClickEvent) {
        let request = navigationRequestGeneration
        if delegate?.readerView(self, didClick: event) != true,
           request == navigationRequestGeneration,
           event.isPlainPrimary {
            // 既定動作: 左右端のタップでページ送り(物理方向。
            // 右綴じなら左=進む — 紙の本のめくり方向と一致)
            if event.x < 0.4 {
                turnPageLeft()
            } else if event.x > 0.6 {
                turnPageRight()
            }
        }
    }

    // MARK: - 余白(WKWebView 外)のネイティブ入力

    // 版面余白(insets)は WKWebView の外側にあり JS の click/wheel 捕捉が
    // 届かない。画像本は view 全域でバインドが効くため、柱・ノンブル領域の
    // クリックとホイールも同じ入力系へ合流させる(WKWebView 内のイベントは
    // WKWebView 自身が消費するのでここへは来ない)

    public override func mouseDown(with event: NSEvent) {
        notePress(event)
        super.mouseDown(with: event)
    }

    public override func otherMouseDown(with event: NSEvent) {
        notePress(event)
        super.otherMouseDown(with: event)
    }

    private func notePress(_ event: NSEvent) {
        marginPress.time = event.timestamp
        marginPress.location = convert(event.locationInWindow, from: nil)
    }

    public override func mouseUp(with event: NSEvent) {
        if !dispatchMarginClick(event, button: 0) { super.mouseUp(with: event) }
    }

    public override func otherMouseUp(with event: NSEvent) {
        if !dispatchMarginClick(event, button: event.buttonNumber) {
            super.otherMouseUp(with: event)
        }
    }

    private func dispatchMarginClick(_ event: NSEvent, button: Int) -> Bool {
        let location = convert(event.locationInWindow, from: nil)
        guard bounds.contains(location),
              !(webView.map { $0.frame.contains(location) } ?? false)
        else { return false }
        // JS の click 抑制(ReaderScripts の suppressAsGesture)と同じ閾値: 30pt 超のドラッグ・1 秒超の
        // 長押しの解放はクリックにしない(イベントは消費する)
        guard event.timestamp - marginPress.time <= 1.0,
              max(abs(location.x - marginPress.location.x),
                  abs(location.y - marginPress.location.y)) <= 30
        else { return true }
        dispatchClick(clickEvent(for: event, button: button))
        return true
    }

    /// ネイティブのマウスイベントを、JS の tap と同じ座標系のクリックへ写す
    /// (y は「上端 0」の正規化。この view は非 flipped)
    private func clickEvent(for event: NSEvent, button: Int) -> EPUBClickEvent {
        let location = convert(event.locationInWindow, from: nil)
        let flags = event.modifierFlags
        return EPUBClickEvent(
            x: Double(location.x / max(1, bounds.width)),
            y: Double(1 - location.y / max(1, bounds.height)),
            locationInView: location,
            button: button,
            shift: flags.contains(.shift),
            option: flags.contains(.option),
            control: flags.contains(.control),
            command: flags.contains(.command))
    }

    public override func scrollWheel(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard bounds.contains(location),
              !(webView.map { $0.frame.contains(location) } ?? false)
        else {
            super.scrollWheel(with: event)
            return
        }
        turnPageByWheel(event)
    }

    /// 余白と WebView の上(ページ表示)のホイールを「1 ジェスチャ = 1 ページ」に
    /// 量子化して送る(250ms 静穏で解除・軸は最初のイベントで確定)。慣性はラッチが飲み込む
    func turnPageByWheel(_ event: NSEvent) {
        // トラックパッドは指を置いた時点で移動量 0 のイベント(mayBegin)を送る。
        // これで軸を決めると縦になり、続く横スワイプを取りこぼす(WebKit は
        // 移動量 0 のイベントを DOM に渡さないので、JS 経路では起きなかった)
        guard event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0 else { return }
        // spine 読み込み中の残存慣性は送りに使わない(boundary と同じく、FXL 項目が
        // 表示される前に advanceSpine で飛ばされるカスケードを防ぐ)。手が動いている
        // ことは記録し、ラッチしたままにする(読み込み後も同じジェスチャが続く間は送らない)
        guard !spineLoad.isLoadingSpineItem else {
            marginWheelLatch.lastTime = event.timestamp
            marginWheelLatch.latched = true
            return
        }
        guard let (horizontal, positive) = marginWheelLatch.register(event) else { return }
        // AppKit の scrollingDelta は DOM の wheel と符号が逆
        // (正=文書の先頭方向へのスクロール)
        if horizontal {
            // 水平めくりはホスト設定でゲート・反転できる(ホストが自前の
            // スワイプめくりを持つ場合に二重発火を避け、綴じ方向をそろえる)
            guard settings.horizontalWheelTurnsPages else { return }
            let towardLeft = positive != settings.reversesHorizontalWheelTurn
            towardLeft ? turnPageLeft() : turnPageRight()
        } else {
            positive ? goBackward() : goForward()
        }
    }
}
