import AppKit

/// EPUBReaderView の全文ページ数の実測(census): 公開 API と本全体の
/// ページ番号変換、画面サムネイル、実測の予約・失敗台帳・停止。
extension EPUBReaderView {
    // MARK: - 全文ページ数の実測(census)

    /// 本全体の総ページ数(census 完了までは nil)。
    ///
    /// Total page count across the whole book (nil until the census completes).
    public var censusTotalPages: Int? { pageCensus?.reduce(0, +) }

    /// 完了した本全体の census を書き出す。ホストが保存し、次に本を開く際に
    /// 再注入すれば、オフスクリーンでの再実測を省ける(N/M のページ表示と
    /// ページバーが即座に現れる)。現在のメトリクスでの census が完了する
    /// までは nil。
    ///
    /// Exports the completed whole-book census so a host can persist it and
    /// re-inject it on a later open, skipping the offscreen re-measure (the
    /// N/M page label and page bar then appear immediately). Nil until the
    /// census for the current metrics has completed.
    public func exportCensus() -> EPUBCensusRecord? {
        guard let counts = pageCensus, let key = pageCensusMetricsKey else {
            return nil
        }
        return EPUBCensusRecord(
            metricsKey: key, counts: counts,
            releaseIdentifier: publication?.metadata.releaseIdentifier)
    }

    /// 以前書き出した census を取り込む。spine 項目数とリリース識別子が
    /// 現在の本と一致する場合に限り受け付ける。リリース識別子には、
    /// 更新日時があればそれを使い、なければパッケージ識別子を使う。
    /// パッケージに一意の識別子がない場合に限り nil になる。
    /// メトリクスキーが現在の表示メトリクスとも一致すれば即座に適用し、
    /// 一致しなければキャッシュして、そのメトリクスで表示が確定した時点で
    /// 適用する。受け付けたかどうかを返す。0 以下のページ数や、合計が `Int` で
    /// オーバーフローするページ数は、現在の census を変更せず拒否する。
    ///
    /// Seeds a previously exported census. It is accepted only if it matches
    /// the current book — same spine item count and same release identifier.
    /// The release identifier uses the modified timestamp when present, then
    /// falls back to the package identifier; it is nil only when the package
    /// has no unique identifier. When its metrics key also matches the current
    /// display metrics, it takes effect immediately; otherwise it is cached and
    /// used the moment the display settles to those metrics. Returns whether it
    /// was accepted. Nonpositive counts and counts whose sum overflows `Int`
    /// are rejected without changing the current census.
    @discardableResult
    public func importCensus(_ record: EPUBCensusRecord) -> Bool {
        guard let publication,
              EPUBScreenMetrics.usesCurrentPaginationVersion(record.metricsKey),
              record.hasValidCounts,
              record.counts.count == publication.readingOrder.count,
              record.releaseIdentifier == publication.metadata.releaseIdentifier
        else { return false }
        census.cache[record.metricsKey] = record.counts
        if record.metricsKey == censusOptionsJSON() {
            census.key = record.metricsKey
            pageCensus = record.counts
            delegate?.readerViewDidUpdatePageCensus(self)
        }
        return true
    }

    /// 完了した census のメトリクスキー(ホストが自身のキャッシュ内で
    /// census を再利用する際に、一致を検証するための値)。実測が完了して
    /// 初めて値を返す。`censusKey` は実測開始時に先行して更新されるため、
    /// それだけでは実測完了を判断できない。
    ///
    /// The metrics key of the completed census (for the host to validate a
    /// match when reusing the census in its own cache). Returns a value only
    /// once the measurement has completed — `censusKey` alone cannot be trusted,
    /// because it is updated ahead of time when the measurement begins.
    public var pageCensusMetricsKey: String? {
        pageCensus != nil ? census.key : nil
    }

    /// spine 項目の先頭ページの、本全体でのオフセット(0 始まり)。
    ///
    /// Whole-book offset of a spine item's first page (0-based).
    public func censusPageOffset(forSpineIndex index: Int) -> Int? {
        guard let pageCensus, index >= 0, index <= pageCensus.count else { return nil }
        return pageCensus.prefix(index).reduce(0, +)
    }

    /// 現在表示中のページの、本全体でのページ番号範囲(1 始まり。
    /// 見開きでは 2 ページ)。実測ページ数と実際の表示ページ数に差が
    /// 生じ得る境界では、範囲がはみ出さないように制限する。
    ///
    /// Whole-book page-number range of the currently displayed pages (1-based;
    /// two pages in a spread). Clamped at boundaries where the measured page
    /// count and the actually displayed count may diverge.
    public var currentGlobalPageRange: ClosedRange<Int>? {
        guard let counts = pageCensus,
              counts.indices.contains(currentSpineIndex),
              let offset = censusPageOffset(forSpineIndex: currentSpineIndex)
        else { return nil }
        let itemPages = counts[currentSpineIndex]
        let first = offset + min(pageInItem, max(0, itemPages - 1)) + 1
        let last = offset + min(pageInItem + pagesPerScreen, itemPages)
        return first...max(first, last)
    }

    /// 本全体のページ番号(0 始まり)を位置へ変換する。census 完了までは nil。
    ///
    /// Whole-book page number (0-based) → position. Nil until the census completes.
    public func censusLocator(forGlobalPage page: Int) -> EPUBLocator? {
        guard let counts = pageCensus, !counts.isEmpty else { return nil }
        var remaining = max(0, page)
        for (index, count) in counts.enumerated() {
            if remaining < count {
                let divisions = censusProgressionDivisions(at: index, count: count)
                let progression = divisions <= 0 ? 0 : Double(remaining) / Double(divisions)
                return publication?.locator(forSpineIndex: index,
                                            progression: progression)
                    ?? EPUBLocator(spineIndex: index, progression: progression)
            }
            remaining -= count
        }
        return publication?.locator(forSpineIndex: counts.count - 1, progression: 1)
            ?? EPUBLocator(spineIndex: counts.count - 1, progression: 1)
    }

    /// 位置を本全体のページ番号(0 始まり)へ変換する。census 完了前、または
    /// locator が実測済みの spine 項目を指していない場合は nil。
    ///
    /// Position → whole-book page number (0-based). Nil until the census
    /// completes or when the locator does not address a measured spine item.
    public func censusGlobalPage(for locator: EPUBLocator) -> Int? {
        guard let locator = publication?.resolve(locator),
              let counts = pageCensus,
              counts.indices.contains(locator.spineIndex) else { return nil }
        let count = counts[locator.spineIndex]
        guard count > 0 else { return nil }
        let offset = counts.prefix(locator.spineIndex).reduce(0, +)
        // censusLocator(forGlobalPage:) と同じ 0 始まり・項目内 (count - 1)
        // 分割へ戻す。rounded() により両方向の量子化を対称にする
        // cooViewer-oxr.73: Double → Int の範囲外変換は SIGTRAP になるため、
        // locator 自身の不変条件だけに依存せず変換直前にも防御する。
        let safeProgression = Self.clampedProgression(locator.progression)
        // Double(Int.max - 1) rounds up beyond Int.max. A clamped progression
        // alone does not make conversion safe for a very large imported count.
        let divisions = censusProgressionDivisions(at: locator.spineIndex, count: count)
        let raw = safeProgression * Double(divisions)
        let value = divisions == count ? (raw + 0.000001).rounded(.down) : raw.rounded()
        let inItem = Int(exactly: value)
            ?? (count - 1)
        return offset + min(max(0, inItem), count - 1)
    }

    private func censusProgressionDivisions(at index: Int, count: Int) -> Int {
        if let publication, publication.renderingFlow(at: index) == .scrolledContinuous,
           index < publication.scrollGroup(containing: index).upperBound - 1 { return count }
        return count - 1
    }

    static func clampedProgression(_ value: Double) -> Double {
        guard !value.isNaN else { return 0 }
        return min(1, max(0, value))
    }

    // MARK: - 画面サムネイル(ホストの一覧 UI 用)

    /// 現在のメトリクスで 1 画面に配置するページ数(1 = 単ページ / 2 = 見開き)。
    /// サムネイル一覧を画面単位に区切るために使う(画像 1 枚だけの項目は
    /// 実行時に 1 になるが、これは「リフローの本文項目ならどうなるか」を
    /// 表す計画値)。
    ///
    /// Number of pages laid out on one screen at the current metrics (1 = single
    /// page / 2 = spread). Used to divide the thumbnail list into screens (a
    /// single-image item resolves to 1 at run time, but this is the planned
    /// value for "what a reflowable text item would be").
    public var plannedPagesPerScreen: Int {
        currentScreenMetrics.pagesPerScreen
    }

    /// 画面計画を単ページと見開きの間で切り替える。``pagesPerScreen`` と
    /// 異なり、画像 1 枚だけのページを表示していても正しく切り替えられる。
    ///
    /// Toggles between planned single-page and two-page layout. Unlike
    /// ``pagesPerScreen``, this remains correct while a single-image page is
    /// displayed.
    public func toggleColumnMode() {
        var updated = settings
        // cooViewer-oxr.20: 表紙の実測値(常に 1)でなく画面計画を反転する。
        updated.columnMode = plannedPagesPerScreen == 2 ? .single : .double
        settings = updated
    }

    /// 指定した画面のサムネイル(表示中のビューや census と同じページ割りで、
    /// 現在のテーマに合わせた配色でオフスクリーン描画する)。`width` は
    /// 出力幅(pt)。失敗時、ウインドウから外れている間、非表示中は nil。
    ///
    /// Thumbnail of a given screen (the same pagination as the live view and the
    /// census; rendered offscreen, colored to match the current theme). `width`
    /// is the output width in pt. Nil on failure, while detached, or while hidden.
    public func screenThumbnail(spineIndex: Int, pageInItem: Int,
                                width: CGFloat) async -> CGImage? {
        // 破棄後に届くホストの先読みで、不可視 WebKit を作り直さない。
        guard allowsVisibleRenderingWork, let publication else { return nil }
        let renderer = thumbnailRenderer
            ?? EPUBScreenThumbnailRenderer(publication: publication)
        thumbnailRenderer = renderer
        let itemMetrics = EPUBScreenMetrics(
            viewportSize: bounds.size, settings: settings,
            renditionSpread: effectiveSpread(forSpineIndex: spineIndex))
            .applyingRenditionFlow(publication.renderingFlow(at: spineIndex))
        return await renderer.thumbnail(
            spineIndex: spineIndex, pageInItem: pageInItem,
            optionsJSON: itemMetrics.themedOptionsJSON(isDark: isDarkEffective),
            contentSize: itemMetrics.contentSize, snapshotWidth: width)
    }

    /// リフロー時のコンテンツ寸法(現在項目が FXL でも「リフロー項目なら
    /// こうなる」寸法。census のメトリクスは現在項目に依存させない)
    private func reflowContentSize() -> NSSize {
        censusScreenMetrics.contentSize
    }

    /// census 用のセットアップオプション(= リフロー項目の setup と同値。
    /// メトリクスの同一性キーとしても使う)
    private func censusOptionsJSON() -> String {
        censusScreenMetrics.censusOptionsJSON
    }

    /// バックグラウンドの census を停止する(ホストが EPUB ビューから
    /// 離れるときに使う。次回の runSetup / layout で自動的に再予約される)。
    ///
    /// Stops the background census (for when the host leaves the EPUB view; it
    /// is naturally rescheduled by the next runSetup / layout).
    public func cancelPageCensus() {
        census.task?.cancel()
        census.task = nil
    }

    /// メトリクスが変わっていれば census を(デバウンス付きで)再実測する。
    /// runSetup 完了時と FXL 表示中のリサイズで呼ぶ — リサイズ・フォント倍率・
    /// 見開き切替に追従する
    func scheduleCensusIfNeeded() {
        guard let publication, !publication.readingOrder.isEmpty else { return }
        // ウインドウから外れている間・非表示中はオフスクリーン計測を始めない
        // (viewDidMoveToWindow で畳んだ直後に runSetup 由来の呼び出しが
        // 実測を復活させ、不可視ウインドウ/プロセスが生き返るのを防ぐ。
        // 再表示されれば layout/runSetup が改めて呼ぶ)
        guard allowsVisibleRenderingWork else {
            repagination.pendingVisibleLayout = true
            return
        }
        let key = censusOptionsJSON()
        // 実測に使う寸法はキーと同じ瞬間に採る(デバウンス起床時に採ると、
        // 窓の終盤のリサイズで「旧キーに新寸法の実測」が入りキャッシュが汚れる)
        let size = reflowContentSize()
        if census.key == key {
            if pageCensus != nil { return }
            // 同一メトリクスで実測中なら継続させる(spine 遷移のたびに
            // runSetup から呼ばれるため、ここで中断すると大きい本で
            // いつまでも完走しない)。成功・失敗・非キャンセル離脱のすべてで
            // censusTask を nil に戻すので(下記 3 経路)、この分岐が再実測を
            // 塞ぐことはない。この不変条件は「censusTask の再代入は必ず先行
            // cancel を伴う」規律(下の Task 生成箇所)に依存する
            if let task = census.task, !task.isCancelled { return }
        }
        if let cached = census.cache[key] {
            census.key = key
            pageCensus = cached
            // 旧キーの計測が走っていれば止める(完走させても無駄なうえ、
            // 同じキーへ戻ったときの並走の種になる)
            census.task?.cancel()
            delegate?.readerViewDidUpdatePageCensus(self)
            return
        }
        if census.failures.shouldSkip(key) {
            // cooViewer-oxr.21: 失敗台帳で再試行を省く場合も、別メトリクスの
            // 成功値を N/M・ページバーへ残してはならない。
            if census.key != key {
                census.task?.cancel()
                census.task = nil
                census.key = key
                pageCensus = nil
                delegate?.readerViewDidUpdatePageCensus(self)
            }
            return
        }
        // 古いメトリクスの番号を出し続けないよう、まず無効化を通知
        if pageCensus != nil {
            pageCensus = nil
            let request = navigationRequestGeneration
            delegate?.readerViewDidUpdatePageCensus(self)
            guard request == navigationRequestGeneration else { return }
        }
        census.key = key
        // 規律: censusTask の再代入は必ず先行 cancel を伴う(上のガードの
        // 不変条件がこれに依存する。この規律を崩すと居座り/取り違えが再発する)
        census.task?.cancel()
        let previous = census.task
        // オフスクリーン WebKit のジョブは明示 .userInitiated で起動する
        // (低 QoS 継承だと最初の JS 実行の返信が返らない。兄弟の census/
        // rasterizer/thumbnail レンダラと規約を揃える)
        census.task = Task(priority: .userInitiated) { [weak self] in
            await Self.runCensus(key: key, size: size, previous: previous) { self }
        }
    }

    /// census の Task 本体。デバウンスと旧計測の離脱を待ってから実測し、結果を写す。
    /// measure の await をまたいで self を強参照しない: ホストが
    /// ビューを手放したら、全 spine 実測(壊れた本は 1 項目 15 秒
    /// タイムアウト×N)を道連れにビューが生き残らないように。そのため
    /// インスタンスメソッドにせず、`reader` の弱参照から都度取り出す
    private static func runCensus(key: String, size: NSSize,
                                  previous: Task<Void, Never>?,
                                  reader: () -> EPUBReaderView?) async {
        // リサイズ嵐・連続の設定変更を合流させる
        try? await Task.sleep(for: .milliseconds(300))
        // 旧計測の完全な離脱を待つ(FIFO 直列化)。同じ WKWebView 上で
        // 新旧の measure が並走すると、ナビゲーションイベントの取り違えで
        // 失敗や「1 項目ずれた実測値」のキャッシュ汚染が起きる
        // (EPUBPageRasterizer と同じ直列化方針)
        _ = await previous?.value
        // キャンセルは素通し(新タスクを潰さない)、非キャンセルの離脱は
        // censusTask を自己退去する(完了済みタスクが居座って再実測を
        // 永久に塞ぐのを防ぐ。成功・失敗経路と対称にする)
        guard !Task.isCancelled else { return }
        guard let publication = reader()?.publication, reader()?.census.key == key
        else { reader()?.census.task = nil; return }
        let engine = reader()?.census.engine ?? EPUBPaginationCensus()
        reader()?.census.engine = engine
        let counts = await engine.measure(
            publication: publication, optionsJSON: key, contentSize: size)
        guard let view = reader(), !Task.isCancelled, view.census.key == key else { return }
        guard let counts else {
            // 失敗完了は「実測中」ではない — タスクを解放して次の
            // runSetup での再実測を許す(回数はキーごとに上限あり + TTL)
            view.recordCensusFailure(forKey: key)
            view.census.task = nil
            return
        }
        view.census.cache[key] = counts
        view.pageCensus = counts
        view.census.task = nil  // 成功完了も自己退去(不変条件を対称に保つ)
        view.delegate?.readerViewDidUpdatePageCensus(view)
    }

    /// cooViewer-oxr.21: 実測経路と決定的な回帰テストで失敗台帳を共有する。
    func recordCensusFailure(forKey key: String) {
        census.failures.recordFailure(key)
    }
}
