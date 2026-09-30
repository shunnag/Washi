import AppKit

/// EPUBReaderView の内部リンク: JS から届いた link 通知の解決と委譲、
/// 注釈内容の抽出、href からの fragment の切り出し。
extension EPUBReaderView {
    /// 捕捉した EPUB 内部リンクの注釈内容を抽出する。
    ///
    /// Extracts note content for an intercepted EPUB internal link.
    ///
    /// 表示中の文書にある注釈には、その内側の HTML を含める。読書順に
    /// 含まれる別の文書にある注釈はヘッドレスで解析し、テキストだけを返す。
    /// どちらの場合も、参照元へ戻るリンクのアンカーは除去する。
    ///
    /// Notes in the displayed document include their inner HTML. Notes in a
    /// different reading-order document are parsed headlessly and return text
    /// only. Backlink anchors are removed in both cases.
    public func noteContent(for link: EPUBInternalLink) async -> EPUBNoteContent? {
        guard let publication, let fragment = link.fragment,
              !fragment.isEmpty,
              let sourceSpineIndex = publication.readingOrder.firstIndex(where: {
                  $0.resolvedContainerPath == link.containerPath
                      || $0.containerPath == link.containerPath
              })
        else { return nil }
        let source = publication.readingOrder[sourceSpineIndex]

        guard sourceSpineIndex == currentSpineIndex,
              !spineLoad.isLoadingSpineItem, let webView else {
            // cooViewer-oxr.32: 別 spine は UI actor を塞がず Core の XML 抽出で読む。
            let text = await Task.detached(priority: .userInitiated) {
                publication.noteText(
                    at: source.resolvedContainerPath, fragment: fragment)
            }.value
            return text.map {
                EPUBNoteContent(text: $0, html: nil,
                                sourceSpineIndex: sourceSpineIndex)
            }
        }

        // cooViewer-oxr.32: fragment は EPUB 由来なので JS 本文へ埋め込まず、
        // callAsyncJavaScript の引数として WebKit に渡す。
        let generation = spineLoadGeneration
        let result = await callWashiAsync(
            """
            const document = __washi.activeDocument ? __washi.activeDocument() : window.document;
            function epubTypeOf(element) {
                return element.getAttributeNS(
                    'http://www.idpf.org/2007/ops', 'type')
                    || element.getAttribute('epub:type') || '';
            }
            function isNoteContainer(element) {
                const tag = (element.localName || '').toLowerCase();
                if (tag !== 'aside' && tag !== 'section') { return false; }
                const types = epubTypeOf(element).toLowerCase()
                    .split(/\\s+/).filter(Boolean);
                const role = (element.getAttribute('role') || '').toLowerCase();
                return types.includes('footnote') || types.includes('endnote')
                    || types.includes('rearnote')
                    || role === 'doc-footnote' || role === 'doc-endnote';
            }
            const target = document.getElementById(fragment);
            if (!target) { return { found: false, text: '', html: '' }; }
            let selected = target;
            const targetTag = (target.localName || '').toLowerCase();
            if (targetTag === 'li' || targetTag === 'p') {
                let ancestor = target.parentElement;
                while (ancestor) {
                    if (isNoteContainer(ancestor)) {
                        selected = ancestor;
                        break;
                    }
                    ancestor = ancestor.parentElement;
                }
            }
            const copy = selected.cloneNode(true);
            // cooViewer-oxr.32: 戻り先が不明な公開 link 値にも一貫して
            // 対応するため、注釈内の fragment-only anchor をすべて除く。
            for (const candidate of Array.from(copy.getElementsByTagName('*'))) {
                if ((candidate.localName || '').toLowerCase() !== 'a') { continue; }
                const href = candidate.getAttribute('href')
                    || candidate.getAttributeNS(
                        'http://www.w3.org/1999/xlink', 'href') || '';
                if (href.trim().startsWith('#')) { candidate.remove(); }
            }
            const html = copy.innerHTML;
            const staging = document.createElement('div');
            staging.style.cssText = 'position:fixed;left:-100000px;top:0;'
                + 'width:1000px;opacity:0;pointer-events:none;z-index:-2147483648;';
            staging.style.setProperty('display', 'block', 'important');
            copy.removeAttribute('hidden');
            copy.style.setProperty('display', 'block', 'important');
            staging.appendChild(copy);
            (document.body || document.documentElement).appendChild(staging);
            let text = '';
            try {
                text = typeof copy.innerText === 'string'
                    ? copy.innerText : (copy.textContent || '');
            }
            finally { staging.remove(); }
            return { found: true, text: text, html: html };
            """,
            arguments: ["fragment": fragment], in: webView)
        guard webView === self.webView,
              generation == spineLoadGeneration,
              currentSpineIndex == sourceSpineIndex,
              let dictionary = result as? [String: Any],
              dictionary["found"] as? Bool == true,
              let text = dictionary["text"] as? String,
              let html = dictionary["html"] as? String
        else { return nil }
        return EPUBNoteContent(text: text, html: html,
                               sourceSpineIndex: sourceSpineIndex)
    }

    /// href からフラグメントを取り出す。split は空要素を落とすため
    /// "#note1" のような同一文書内リンクで壊れないよう firstIndex で切る
    static func fragment(of href: String) -> String? {
        guard let hash = href.firstIndex(of: "#") else { return nil }
        let encoded = String(href[href.index(after: hash)...])
        guard !encoded.isEmpty else { return nil }
        // cooViewer-oxr.32: DOM id は URI fragment の percent decode 後の値で
        // 照合する。不正な escape は実在本を壊さないよう原文へ fallback する。
        return encoded.removingPercentEncoding ?? encoded
    }

    func handleLink(_ message: [String: Any]) {
        guard let publication,
              publication.readingOrder.indices.contains(currentSpineIndex),
              let href = message["href"] as? String else { return }
        // 外部リンク(スキーム付き)
        if let url = URL(string: href), let scheme = url.scheme?.lowercased(),
           ["http", "https", "mailto"].contains(scheme) {
            if delegate?.readerView(self, shouldOpenExternalURL: url) ?? true {
                NSWorkspace.shared.open(url)
            }
            return
        }
        let currentPath = publication.readingOrder[currentSpineIndex]
            .resolvedContainerPath
        guard let path = ContainerPath.resolve(base: currentPath, href: href) else {
            return
        }
        let epubType = message["epubType"] as? String
        let role = message["role"] as? String
        let link = EPUBInternalLink(
            href: href,
            containerPath: path,
            fragment: Self.fragment(of: href),
            targetSpineIndex: publication.readingOrder.firstIndex {
                $0.resolvedContainerPath == path || $0.containerPath == path
            },
            epubType: epubType,
            role: role,
            isNoteReference: epubType?.lowercased().contains("noteref") == true
                || role?.caseInsensitiveCompare("doc-noteref") == .orderedSame,
            hasBacklink: message["backlink"] as? Bool ?? false,
            targetEpubType: message["targetEpubType"] as? String,
            anchorRect: (message["anchorRect"] as? [String: Any])
                .flatMap { raw in
                    guard let webView else { return nil }
                    return readerViewRect(from: raw, in: webView)
                })
        // cooViewer-oxr.32: delegate の拒否を履歴記録より先に確定し、既定経路は
        // goToContainerPath の一回だけにして二重記録を避ける。
        let request = navigationRequestGeneration
        guard delegate?.readerView(self, shouldFollowInternalLink: link) ?? true,
              request == navigationRequestGeneration
        else { return }
        goToContainerPath(path, fragment: link.fragment)
    }
}
