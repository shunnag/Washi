import Foundation

/// メディアオーバーレイの解析モデル(EPUB 3 Media Overlays、SMIL の部分集合)。
/// 再生は Washi ターゲットの `EPUBReaderView.playMediaOverlay()` が提供する。
///
/// Parsing model for a media overlay (EPUB 3 Media Overlays, a SMIL subset).
/// Playback is provided by `EPUBReaderView.playMediaOverlay()` in the Washi target.
public struct MediaOverlay: Sendable {
    /// par: テキスト断片と音声クリップを同期させる組。
    ///
    /// par: a synchronization pair of a text fragment and an audio clip.
    public struct Parallel: Sendable {
        /// 対応するコンテンツ文書の href(フラグメントを含む、SMIL からの相対参照)。
        ///
        /// href of the corresponding content document (fragment included, relative to the SMIL).
        public let textHref: String?
        /// 音声ファイルの href。
        ///
        /// href of the audio file.
        public let audioHref: String?
        /// クリップの開始位置(秒単位、省略時は 0)。
        ///
        /// Clip start in seconds (0 when omitted).
        public let clipBegin: Double
        /// クリップの終了位置(秒単位、省略時はメディアの終端)。
        ///
        /// Clip end in seconds (end of media when omitted).
        public let clipEnd: Double?
        /// この par とその祖先の epub:type トークン(footnote / pagebreak など、
        /// スキップ可否の判定に使う)。
        ///
        /// epub:type tokens on this par and its ancestors (used to decide
        /// skippability: footnote / pagebreak, etc.).
        public let epubType: String?
    }

    /// par エントリを再生順に平坦化した一覧。
    ///
    /// The par entries flattened into playback order.
    public let parallels: [Parallel]
    /// SMIL 文書のコンテナ内パス(href 解決の基準)。
    ///
    /// Container-internal path of the SMIL document (the base for href resolution).
    public let basePath: String
}

extension EPUBPublication {
    /// メディアオーバーレイ(SMIL による読み上げ)を宣言する spine 項目があるか。
    /// 項目ごとの解析済みクリップは ``mediaOverlay(forSpineIndex:)`` で取得する。
    ///
    /// Whether any spine item declares a media overlay (SMIL narration). Use
    /// ``mediaOverlay(forSpineIndex:)`` to get the parsed clips for one item.
    public var hasMediaOverlays: Bool {
        readingOrder.contains { $0.item.mediaOverlay != nil }
    }

    /// cooViewer-oxr.46 C07: その spine 項目が参照する SMIL のコンテナ内パス。
    /// 1 つの SMIL が複数の XHTML を束ねる本では、隣り合う項目が同じ SMIL を
    /// 指す。同じものを頭から鳴らし直さないための識別子に使う。
    ///
    /// cooViewer-oxr.46 C07: The container-internal path of the SMIL referenced
    /// by that spine item. In books where one SMIL groups multiple XHTML
    /// documents, adjacent items refer to the same SMIL. Used as an identifier
    /// to avoid restarting the same overlay from the beginning.
    public func mediaOverlayPath(forSpineIndex index: Int) -> String? {
        guard readingOrder.indices.contains(index) else { return nil }
        guard let overlayID = readingOrder[index].item.mediaOverlay,
              let overlayItem = package.manifestByID[overlayID] else { return nil }
        return containerPath(forHref: overlayItem.href, relativeTo: package.path)
    }

    /// spine 項目に対応するメディアオーバーレイを読み込む(なければ nil)。
    ///
    /// Loads the media overlay associated with a spine item (nil if none).
    public func mediaOverlay(forSpineIndex index: Int) -> MediaOverlay? {
        guard let path = mediaOverlayPath(forSpineIndex: index),
              let data = try? resource(at: path).data else { return nil }
        return try? SMILParser.parse(data: data, at: path)
    }
}
