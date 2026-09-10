import Foundation

/// メディアオーバーレイ(SMIL)再生の公開 API と、コントローラが使う内部フック。
/// 再生・一時停止・停止と、テキストのハイライト/ページ追従を仲介する
extension EPUBReaderView {
    /// media:active-class の既定(本が宣言していないとき)
    static let defaultActiveClass = "-epub-media-overlay-active"

    /// 現在の spine 項目がメディアオーバーレイ(音声同期)を持つか
    ///
    /// Whether the current spine item has a media overlay (synchronized audio).
    public var hasMediaOverlayForCurrentItem: Bool {
        publication?.mediaOverlay(forSpineIndex: currentSpineIndex) != nil
    }

    /// この本のどこかにメディアオーバーレイがあるか
    ///
    /// Whether any part of this book has a media overlay.
    public var hasMediaOverlays: Bool {
        publication?.hasMediaOverlays ?? false
    }

    /// メディアオーバーレイを再生中か
    ///
    /// Whether a media overlay is currently playing.
    public var isPlayingMediaOverlay: Bool {
        mediaOverlayController?.isPlaying ?? false
    }

    /// メディアオーバーレイの再生を開始/再開する。現在の項目が音声を持たない
    /// ときは何もしない。項目末尾では次の音声付き項目へ連続再生する
    ///
    /// Starts or resumes media overlay playback. Does nothing if the current
    /// spine item has no audio. At the end of the item, playback continues
    /// with the next item that has audio.
    public func playMediaOverlay() {
        mediaOverlayCommandGeneration &+= 1
        guard let publication, hasMediaOverlayForCurrentItem else { return }
        if let controller = mediaOverlayController {
            if controller.isPlaying { return }
            // 一時停止後に別の章へ移動していたら、その章の先頭から始め直す
            // (古い章の音声を再開しない)
            if controller.spineIndex == currentSpineIndex {
                controller.resume()
            } else {
                controller.play(fromSpineIndex: currentSpineIndex)
            }
            return
        }
        let activeClass = publication.metadata.mediaOverlayActiveClass
            ?? Self.defaultActiveClass
        let controller = MediaOverlayController(
            reader: self, publication: publication, activeClass: activeClass)
        controller.playbackRate = settings.mediaOverlayPlaybackRate
        controller.skippedTypes = settings.mediaOverlaySkippedTypes
        mediaOverlayController = controller
        controller.play(fromSpineIndex: currentSpineIndex)
    }

    /// 章の先頭ではなく、現在のページに本文が見えているクリップから
    /// 読み上げを開始する(cooViewer-oxr.46 C26)。ページ内に読み上げ対象が
    /// なければ、章の先頭から始める。
    ///
    /// Starts narration at the clip whose text is visible on the current page,
    /// instead of at the start of the chapter (cooViewer-oxr.46 C26).
    /// Falls back to the chapter start when nothing on the page is narrated.
    public func playMediaOverlayFromCurrentPage() async {
        mediaOverlayCommandGeneration &+= 1
        let command = mediaOverlayCommandGeneration
        guard let publication,
              let overlay = publication.mediaOverlay(forSpineIndex: currentSpineIndex)
        else { return }
        let sourceSpineIndex = currentSpineIndex
        let sourceContext = mediaOverlayDocumentContext()
        func belongsToSourceSpine(_ par: MediaOverlay.Parallel) -> Bool {
            guard let href = par.textHref else { return false }
            let document = href.split(separator: "#", maxSplits: 1,
                                      omittingEmptySubsequences: false)[0]
            if document.isEmpty { return true }
            guard let path = ContainerPath.resolve(base: overlay.basePath,
                                                   href: String(document)) else {
                return false
            }
            return publication.spineIndex(forContainerPath: path) == sourceSpineIndex
        }
        let candidates = overlay.parallels.enumerated().compactMap {
            index, par -> (index: Int, identifier: String)? in
            guard belongsToSourceSpine(par), let href = par.textHref else { return nil }
            let parts = href.split(separator: "#", maxSplits: 1,
                                   omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[1].isEmpty else { return nil }
            let rawIdentifier = String(parts[1])
            return (index, rawIdentifier.removingPercentEncoding ?? rawIdentifier)
        }
        var parIndex = overlay.parallels.firstIndex(where: belongsToSourceSpine) ?? 0
        if !candidates.isEmpty,
           let result = await callWashiReturning(
               "return __washi.firstVisibleIdentifier(ids);",
               arguments: ["ids": candidates.map(\.identifier)]),
           let visible = result as? String,
           let candidate = candidates.first(where: { $0.identifier == visible }) {
            parIndex = candidate.index
        }
        // The JavaScript round trip can outlive stop(), another play command,
        // a page turn, a spine load, or even replacement of the publication.
        // An old answer must not start narration in that newer context.
        guard !Task.isCancelled,
              command == mediaOverlayCommandGeneration,
              sourceContext == mediaOverlayDocumentContext(),
              self.publication === publication else { return }
        _ = startMediaOverlay(publication: publication,
                              atSpineIndex: sourceSpineIndex,
                              parIndex: parIndex)
    }

    /// メディアオーバーレイの再生位置(spine 項目 + クリップ番号)。
    /// ホストが聴取の中断位置を保存するために使う。アイドル時は `nil`。
    ///
    /// The media-overlay playback position (spine item + clip index), for a host
    /// that persists where the reader stopped listening. `nil` when idle.
    public var mediaOverlayPosition: (spineIndex: Int, parIndex: Int)? {
        mediaOverlayController?.position
    }

    /// 保存した位置から読み上げを再開する(``mediaOverlayPosition`` を参照)。
    /// 指定した spine 項目にメディアオーバーレイがなければ false を返す。
    ///
    /// Resumes narration at a saved position (see ``mediaOverlayPosition``).
    /// Returns false when the book has no overlay at that spine item.
    @discardableResult
    public func playMediaOverlay(atSpineIndex index: Int, parIndex: Int) -> Bool {
        mediaOverlayCommandGeneration &+= 1
        guard let publication else { return false }
        return startMediaOverlay(publication: publication,
                                 atSpineIndex: index, parIndex: parIndex)
    }

    @discardableResult
    private func startMediaOverlay(publication: EPUBPublication,
                                   atSpineIndex index: Int,
                                   parIndex: Int) -> Bool {
        guard self.publication === publication,
              publication.mediaOverlay(forSpineIndex: index) != nil else { return false }
        let activeClass = publication.metadata.mediaOverlayActiveClass
            ?? Self.defaultActiveClass
        let controller = mediaOverlayController
            ?? MediaOverlayController(reader: self, publication: publication,
                                      activeClass: activeClass)
        controller.playbackRate = settings.mediaOverlayPlaybackRate
        controller.skippedTypes = settings.mediaOverlaySkippedTypes
        mediaOverlayController = controller
        controller.play(fromSpineIndex: index, parIndex: parIndex)
        return true
    }

    /// 一時停止(ハイライトは残す)
    ///
    /// Pauses playback, keeping the highlight.
    public func pauseMediaOverlay() {
        mediaOverlayCommandGeneration &+= 1
        mediaOverlayController?.pause()
    }

    /// 停止してハイライトを消す
    ///
    /// Stops playback and clears the highlight.
    public func stopMediaOverlay() {
        mediaOverlayCommandGeneration &+= 1
        mediaOverlayController?.stop()
    }

    /// 再生⇔一時停止のトグル
    ///
    /// Toggles between playback and pause.
    public func toggleMediaOverlayPlayback() {
        if isPlayingMediaOverlay { pauseMediaOverlay() } else { playMediaOverlay() }
    }

    // MARK: - コントローラ用の内部フック

    /// 指定断片へハイライトを移し、必要ならそのページへめくる(id=nil で解除)。
    /// 断片 id・クラス名は EPUB 由来(信頼できない)ので、文字列連結ではなく
    /// callAsyncJavaScript の引数として渡し WebKit に完全にエスケープさせる
    /// (手動 \\・' エスケープでは \n・\r・U+2028・U+2029 を取りこぼす)
    func mediaOverlayHighlight(fragmentID: String?, cssClass: String) {
        let idArg: Any
        if let fragmentID { idArg = fragmentID } else { idArg = NSNull() }
        callWashiAsync("return __washi.mediaOverlayHighlight(id, cls);",
                       arguments: ["id": idArg, "cls": cssClass])
    }

    /// 連続再生で次の項目へ移動する(先頭から表示)
    func navigateForMediaOverlay(toSpineIndex index: Int) {
        guard let publication,
              publication.readingOrder.indices.contains(index) else { return }
        goToContainerPath(publication.readingOrder[index].containerPath,
                          fragment: nil, recordsHistory: false)
    }

    /// 再生状態の変化を delegate へ通知
    func mediaOverlayPlayingChanged(_ isPlaying: Bool) {
        delegate?.readerView(self, isPlayingMediaOverlayDidChange: isPlaying)
    }

    /// 本の末尾まで再生し終えた
    func mediaOverlayDidFinish() {
        delegate?.readerViewMediaOverlayDidFinish(self)
    }
}
