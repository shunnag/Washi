import AppKit

/// EPUBReaderView の柱・ノンブルと印刷ページ、アクセシビリティ:
/// ノンブルの配置と更新、現在の印刷ページ、読み上げ用のメタデータと通知。
extension EPUBReaderView {
    /// cooViewer-oxr.35: native のノンブルは見た目だけの furniture なので、
    /// NSTextField に hit を奪わせず余白と同じ reader-view 入力経路へ通す。
    ///
    /// cooViewer-oxr.35: Native folios are purely visual page furniture, so
    /// route hits through the reader-view input path used for the margins
    /// instead of letting NSTextField intercept them.
    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard let target = super.hitTest(point) else { return nil }
        if pageNumberLabels.contains(where: {
            target === $0 || target.isDescendant(of: $0)
        }) {
            return self
        }
        return target
    }

    /// ノンブルを各ページの下部中央に置く(Apple Books の版面に倣う。
    /// 見開き時は左右のページそれぞれの下、単ページ時は中央)。
    /// AppKit 座標系: 下原点
    func layoutFurniture() {
        let insets = activeInsets
        let contentWidth = max(1, bounds.width - insets.left - insets.right)
        // ページスロットの中心 x(見開きはノドを挟んだ半幅 2 面)
        let centers: [CGFloat]
        if pagesPerScreen == 2 {
            let gutter = spreadGutter(forContentWidth: contentWidth)
            let pageWidth = (contentWidth - gutter) / 2
            centers = [insets.left + pageWidth / 2,
                       insets.left + contentWidth - pageWidth / 2]
        } else {
            centers = [insets.left + contentWidth / 2]
        }
        for (index, label) in pageNumberLabels.enumerated() {
            guard index < centers.count, !label.isHidden else { continue }
            label.sizeToFit()
            let size = label.frame.size
            label.frame = NSRect(
                x: centers[index] - size.width / 2,
                y: (insets.bottom - size.height) / 2,
                width: size.width, height: size.height)
        }
    }

    /// 各ページのノンブル(素の章内ページ番号。Apple Books 風)を更新する。
    /// FXL・画像ページ(表紙)では隠す。右綴じは右スロットが先のページ
    func updateFurniture() {
        let visible = settings.showsPageFurniture && publication != nil
            && !isFixedLayoutItem && !isRollItem && !isImagePage && !isImageOnlyItem
            && !furnitureSuppressed && !spineLoad.isAwaitingCommit
        guard visible else {
            for label in pageNumberLabels { label.isHidden = true }
            updateAccessibilityMetadata()
            return
        }
        // スロット順 = [左, 右]。表示ページ順は実際の CSS カラム方向で決まる。
        let slotNumbers = pageFurnitureSlotNumbers
        for (index, label) in pageNumberLabels.enumerated() {
            if let number = slotNumbers[index] {
                if settings.showsPrintPageInFurniture,
                   let currentPrintPage {
                    label.stringValue = "\(number) [p. \(currentPrintPage)]"
                } else {
                    label.stringValue = String(number)
                }
                label.isHidden = false
            } else {
                label.isHidden = true
            }
        }
        layoutFurniture()
        updateAccessibilityMetadata()
    }

    /// 可視カラムと共有するノンブル配置。internal は実 WK 回帰試験用。
    var pageFurnitureSlotNumbers: [Int?] {
        let first = pageInItem + 1
        let second = pageInItem + 2 <= pageCountInItem ? pageInItem + 2 : nil
        if pagesPerScreen == 2 {
            return firstPageOnRight ? [second, first] : [first, second]
        }
        return [first, nil]
    }

    // MARK: - 印刷ページ / アクセシビリティ

    /// cooViewer-oxr.38: 現在 spine の最後の marker を優先し、章頭より前なら
    /// page-list 上で直前 spine を指す最後のラベルへフォールバックする。
    func updateCurrentPrintPage() {
        let local = printPageMarkers.last {
            $0.page <= pageInItem
        }?.label
        let fallback = flattenedPrintPageList.last { item in
            guard let publication,
                  let index = publication.spineIndex(forNavItem: item) else {
                return false
            }
            return index < currentSpineIndex
        }?.title
        setCurrentPrintPage(local ?? fallback)
    }

    func setCurrentPrintPage(_ label: String?) {
        guard label != currentPrintPage else { return }
        currentPrintPage = label
        updateAccessibilityMetadata()
        delegate?.readerView(self, didChangePrintPage: label)
    }

    private var localizedPageValue: String {
        let language = accessibilityPreferredLanguageOverride
            ?? Locale.preferredLanguages.first ?? "en"
        if language.lowercased().hasPrefix("ja") {
            return "ページ \(pageInItem + 1) / \(pageCountInItem)"
        }
        return "Page \(pageInItem + 1) of \(pageCountInItem)"
    }

    func updateAccessibilityMetadata() {
        let title = publication?.metadata.mainTitle?.trimmingCharacters(
            in: .whitespacesAndNewlines)
        let label = title.flatMap { $0.isEmpty ? nil : "EPUB reader — \($0)" }
            ?? "EPUB reader"
        setAccessibilityLabel(label)
        let value = settings.showsPrintPageInFurniture
            ? currentPrintPage.map { "\(localizedPageValue) [p. \($0)]" }
                ?? localizedPageValue
            : localizedPageValue
        setAccessibilityValue(value)
    }

    /// cooViewer-oxr.37: pageChanged の短い連続を最後の確定位置へ畳み、同じ
    /// spine/page/count の重複通知を読み上げない。
    func scheduleAccessibilityPageAnnouncement() {
        accessibilityAnnouncementTask?.cancel()
        accessibilityAnnouncementTask = nil
        guard settings.announcesPageChanges else { return }
        let identity = SettledPageIdentity(
            spineIndex: currentSpineIndex, page: pageInItem,
            pageCount: pageCountInItem)
        guard identity != lastAnnouncedPage else { return }
        let message = localizedPageValue
        let delay = accessibilityAnnouncementDelay
        accessibilityAnnouncementTask = Task { @MainActor [weak self] in
            if delay != .zero { try? await Task.sleep(for: delay) }
            guard let self, !Task.isCancelled,
                  !self.spineLoad.isLoadingSpineItem,
                  self.currentSpineIndex == identity.spineIndex,
                  self.pageInItem == identity.page,
                  self.pageCountInItem == identity.pageCount else { return }
            self.accessibilityAnnouncementTask = nil
            if let handler = self.accessibilityAnnouncementHandler {
                self.lastAnnouncedPage = identity
                handler(message)
                return
            }
            guard NSWorkspace.shared.isVoiceOverEnabled else { return }
            self.lastAnnouncedPage = identity
            NSAccessibility.post(
                element: self,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: message,
                    .priority: NSAccessibilityPriorityLevel.medium,
                ])
        }
    }
}
