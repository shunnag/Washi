import AppKit
import WebKit

/// EPUBReaderView のスナップショット: Web コンテンツの撮影と、
/// 余白・ノンブルを含む「紙のページ全体」の合成。
extension EPUBReaderView {
    // MARK: - スナップショット

    /// Web コンテンツそのもののスナップショットと、リーダービューの
    /// 座標系で表したフレームを返す。ライブ Web ビューは自身の寸法を
    /// 超えるスナップショットを作れない。結果はバッキングスケールになるため、
    /// `scale` は幅の縮小にのみ働く。
    ///
    /// Returns a snapshot of the raw web content and its frame in the reader
    /// view's coordinate system. The live web view cannot be snapshotted above
    /// its own size; the result is at backing scale, so `scale` only ever
    /// reduces the width.
    public func contentSnapshot(scale: CGFloat) async throws
        -> (image: NSImage, frame: CGRect) {
        guard let webView else { throw EPUBError.malformed("本が開かれていない") }
        guard scale.isFinite, scale > 0,
              webView.bounds.width.isFinite, webView.bounds.width > 0,
              webView.bounds.height.isFinite, webView.bounds.height > 0 else {
            throw EPUBError.malformed("スナップショットの寸法が無効")
        }
        let configuration = Self.snapshotConfiguration(afterScreenUpdates: true)
        // cooViewer-hnt: snapshotWidth の単位は画素ではなく点。拡大要求は
        // WebKit にクランプされるため、live view の幅を上限にする。
        configuration.snapshotWidth = NSNumber(
            value: max(1, min(Double(webView.bounds.width),
                              Double(webView.bounds.width) * Double(min(scale, 1)))))
        let image = try await webView.takeSnapshot(configuration: configuration)
        return (image, webView.frame)
    }

    /// ビュー全体(余白 + Web コンテンツ)を合成した画像を返す。
    /// WKWebView はレイヤー経由の描画(cacheDisplay など)には現れないため、
    /// takeSnapshot の結果を背景の上に合成する(ヘッドレス検証、サムネイル、
    /// ページめくり演出用)。
    ///
    /// Returns an image compositing the whole view (margins + web content).
    /// WKWebView does not appear in layer-based drawing (cacheDisplay, etc.),
    /// so the result of takeSnapshot is composited over the background (for
    /// headless verification, thumbnails, and the page-turn effects).
    public func snapshot() async throws -> NSImage {
        guard let webView else { throw EPUBError.malformed("本が開かれていない") }
        guard webView.bounds.width.isFinite, webView.bounds.width > 0,
              webView.bounds.height.isFinite, webView.bounds.height > 0 else {
            throw EPUBError.malformed("スナップショットの寸法が無効")
        }
        let webImage = try await webView.takeSnapshot(
            configuration: Self.snapshotConfiguration(afterScreenUpdates: true))
        return composeFullPage(webImage: webImage, in: webView.frame)
    }

    /// takeSnapshot の設定。afterScreenUpdates は「描画完了を待つか」
    /// (演出の新ページは待つ。旧ページと控えは今の合成を即座に撮る)
    static func snapshotConfiguration(afterScreenUpdates: Bool) -> WKSnapshotConfiguration {
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = afterScreenUpdates
        return configuration
    }

    /// Int 変換・行長・総画素の割当を、AppKit を呼ぶ前に検証する。
    /// 既存の小数切捨ては保ち、画面合成 1 枚の予算は最大 256 MiB とする。
    static func snapshotPixelDimensions(size: CGSize, scale: CGFloat) -> (width: Int, height: Int)? {
        guard size.width.isFinite, size.height.isFinite, scale.isFinite,
              size.width > 0, size.height > 0, scale > 0,
              let width = Int(exactly: max(1, (size.width * scale).rounded(.towardZero))),
              let height = Int(exactly: max(1, (size.height * scale).rounded(.towardZero))) else { return nil }
        let (rowBytes, rowOverflow) = width.multipliedReportingOverflow(by: 4)
        let (bytes, sizeOverflow) = rowBytes.multipliedReportingOverflow(by: height)
        guard !rowOverflow, !sizeOverflow, bytes <= 256 * 1024 * 1024 else { return nil }
        return (width, height)
    }

    /// 背景(余白)+本文+ノンブルを 1 枚に焼いた「紙のページ全体」の像。
    /// snapshot()(検証・サムネイル)とページめくり演出が共用する:
    /// webView のスナップショットには本文領域しか写らないため、めくりを
    /// 実際の本のように余白ごと動かすにはこの合成が要る。
    /// 演出側は cgImage(forProposedRect:) でビットマップを取り出すので、
    /// 描画ハンドラ形式(環境によっては 1x で取り出されて文字がぼける)では
    /// なく、backing scale のビットマップへ直接合成して解像度を固定する
    func composeFullPage(webImage: NSImage, in webFrame: NSRect) -> NSImage {
        let size = bounds.size
        let scale = window?.backingScaleFactor ?? 2
        guard let pixels = Self.snapshotPixelDimensions(size: size, scale: scale),
              let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels.width, pixelsHigh: pixels.height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return webImage }
        rep.size = size
        let background = NSColor(cgColor: layer?.backgroundColor
            ?? NSColor.textBackgroundColor.cgColor) ?? .white
        let furniture = pageNumberLabels
            .filter { !$0.isHidden }
            .map { (text: $0.attributedStringValue, frame: $0.frame,
                    color: $0.textColor ?? .secondaryLabelColor,
                    font: $0.font ?? .systemFont(ofSize: 11)) }
        NSGraphicsContext.saveGraphicsState()
        if let context = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = context
            background.setFill()
            NSRect(origin: .zero, size: size).fill()
            webImage.draw(in: webFrame)
            for item in furniture {
                // 柱・ノンブルも合成する(ページと一緒にめくれて見えるように)
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: item.font, .foregroundColor: item.color,
                ]
                NSAttributedString(string: item.text.string,
                                   attributes: attributes).draw(in: item.frame)
            }
            context.flushGraphics()
        }
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }
}
