import Foundation

// Swift と注入 JS(ReaderScripts.pageScript / continuousScrollScript)の
// 橋渡し契約。文字列は WKScriptMessage の body と setup の引数・戻り値に
// そのまま現れる実行時契約で、ホストが観測するものもあるため変更しない。
// ReaderScriptContractTests が JS 側の文字列とこれらの列挙の一致を検証する。
//
// 共通: JS が post する全メッセージは `type` を持ち、setup で受け取った
// documentToken を `token` に載せる(pageScript は空なら省略、連続スクロール
// 文書は常に '' 以上を付ける)。連続スクロール文書が章から中継する
// メッセージには `spineIndex`(章の spine 番号)が加わる。native は token と
// spineIndex で「今表示している文書からの通知か」を判別する。
//
// 各メッセージの payload:
// - pageChanged: page(表示中スプレッドの先頭ページ、0 始まり)、pageCount、
//   mode(computed writing-mode 'htb' / 'vrl' / 'vlr')、pagesPerScreen(1 / 2)。
//   スクロール表示では progression(0...1)も付く。連続スクロール文書では
//   spineIndex・progression・printPageMarkers([{ label, page }])が加わり、
//   pagesPerScreen は常に 1。
// - boundary: forward(Bool)。文書の端でこれ以上めくれないときに送る。
// - wheelTurn: forward(Bool、蓄積量が正)、horizontal(Bool、水平ジェスチャ)。
//   ページ送り表示だけが送る。
// - link: href、epubType(String?)、role(String?)、anchorId(String?)、
//   anchorRect({ x, y, w, h }、viewport 座標)、backlink(Bool)、
//   targetTag(String?)、targetEpubType(String?)。同一文書内の行き先が
//   見つかったときだけ target* と backlink が埋まる。
// - tap: x・y(0...1 の正規化座標)、button(DOM のボタン番号)、
//   shift・alt・ctrl・meta(Bool)。リンク以外のクリックと auxclick。
// - selection: text(String。'' は選択解除)。非空なら start・end(抽出本文の
//   UTF-16 位置、end は排他)と rects([{ x, y, w, h }])が付く。
// - key: key・code(String)、shift・alt・ctrl・meta(Bool)。keysEnabled が
//   false のときだけ keydown を転送する。
// - scrollFailure: reason(String)。連続スクロール文書が準備後の遅延読み込みに
//   失敗したときだけ送る。
//
// setup / repaginate は EPUBScriptSetupOptionKey の鍵を持つ辞書を受け取り、
// EPUBScriptSetupResultKey の鍵を全て持つ辞書を返す。戻り値の mode だけは
// FXL で 'fxl' になる(pageChanged の mode は常に writing-mode)。

/// JS から native へ届くメッセージの種別(`type` の値)。
enum EPUBScriptMessage: String, CaseIterable {
    case pageChanged
    case boundary
    case wheelTurn
    case link
    case tap
    case selection
    case key
    case scrollFailure
}

/// setup / repaginate の戻り値が必ず持つ鍵。
enum EPUBScriptSetupResultKey: String, CaseIterable {
    /// 項目内ページ数(FXL・画像ページは 1)。
    case pageCount
    /// computed writing-mode('htb' / 'vrl' / 'vlr')。FXL だけ 'fxl'。
    case mode
    /// 画像 1 枚だけのページとして中央フィット表示したか。
    case imagePage
    /// 1 画面のページ数(1 / 2)。
    case pagesPerScreen
    /// 見開き末尾の空列を含む内部スクロール列数(native へは公開しない容量)。
    case paddedPageCount
    /// 印刷ページ境界 [{ label, page }]。
    case printPageMarkers
    /// 見開きで先頭ページが右スロットに来るか(右綴じ)。
    case firstPageOnRight
    /// WebKit が -webkit-column-axis に対応しているか。
    case supportsColumnAxis
}

/// setup / repaginate に渡す辞書の鍵。native(EPUBReaderView、
/// EPUBScreenMetrics、EPUBScrollDocument)が組み立てる。
///
/// JS が読む鍵のほかに、native だけが使い JS は無視する鍵も同じ辞書に載る
/// (`engine`・`allowsScriptedContent`・`_washiMetrics`)。census の
/// cacheKey はこの辞書の JSON そのものなので、鍵の文字列は変えない。
/// `continuousItems` の各要素は `index`・`url`・`roll`・`renderable` と、
/// roll 項目だけ `width`・`height` を持つ(EPUBScrollDocument が組み立て、
/// 連続スクロール文書の JS が読む入れ子の鍵で、この列挙には含めない)。
enum EPUBScriptSetupOptionKey: String, CaseIterable {
    case width
    case height
    case gap
    case spread
    case gutter
    case fixedLayout
    case flow
    case keysEnabled
    case documentToken
    case deferTaps
    case doubleClickDelayMS
    case fontScale
    case defaultFontCSS
    case userCSS
    /// 連続スクロール文書だけ: 表示を始める章の spine 番号。
    case spineIndex
    /// 連続スクロール文書だけ: 章の一覧 [{ index, url, roll, renderable, width?, height? }]。
    case continuousItems
    /// native だけ(census / サムネイル): ページ割り規則の版
    /// (EPUBScreenMetrics.paginationVersion)。cacheKey を版で無効化する。
    case engine
    /// native だけ(census / サムネイル): 著者スクリプトの許可。オフスクリーンの
    /// WebView 構成と cacheKey に効く。
    case allowsScriptedContent
    /// native だけ(census / サムネイル): 項目ごとの spread と余白を再計算する
    /// ための不透明な文脈(EPUBScreenMetrics.setupPlan が読む)。
    case washiMetrics = "_washiMetrics"
}

/// setup の引数・戻り値の辞書を、生の文字列ではなく上の列挙で引く。
/// 文字列は rawValue そのものなので、JSON の形は変わらない。
extension Dictionary where Key == String, Value == Any {
    /// EPUBScriptSetupOptionKey を鍵にした並びから setup の引数辞書を作る
    /// (鍵の順序は JSON の直列化に影響しない)。
    init(setupOptions: KeyValuePairs<EPUBScriptSetupOptionKey, Any>) {
        self.init(minimumCapacity: setupOptions.count)
        for (key, value) in setupOptions {
            self[key.rawValue] = value
        }
    }

    subscript(key: EPUBScriptSetupResultKey) -> Any? {
        self[key.rawValue]
    }

    subscript(key: EPUBScriptSetupOptionKey) -> Any? {
        get { self[key.rawValue] }
        set { self[key.rawValue] = newValue }
    }
}
