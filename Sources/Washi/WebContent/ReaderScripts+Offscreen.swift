import Foundation

extension ReaderScripts {
    /// 画面外スナップショットの前に、画像のデコード(必要ならフォントの
    /// 読み込みも)を有界に待つ JS。`timeoutMS` を過ぎたら false で戻る。
    /// cooViewer-oxr.2: 一度も表示しないウインドウでは rAF が発火しないため
    /// 待ってはいけない。img.decode() は Promise ベースで rAF/可視性に
    /// 依存しない。描画の確定は takeSnapshot(afterScreenUpdates: true)に任せる。
    /// content world は呼び出し側が選ぶ(ラスタライザは .defaultClient、
    /// サムネイルは WashiContentWorld.world)。
    static func awaitDecodedImagesScript(awaitFonts: Bool, timeoutMS: Int = 1500) -> String {
        let fontsLine = awaitFonts ? "    await document.fonts.ready;\n" : ""
        return """
        const work = (async () => {
        \(fontsLine)    await Promise.all([...document.images].map(
                image => image.decode().catch(() => {})));
            return true;
        })();
        return await Promise.race([
            work,
            new Promise(resolve => setTimeout(() => resolve(false), \(timeoutMS)))
        ]);
        """
    }
}
