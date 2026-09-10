import AppKit
import Foundation
// EPUBLocator は解析層(WashiCore)へ移動した(EPUBPublication.resolve が使い、
// 表示層に依存しない値型のため)。@_exported 再輸出で import Washi からも見える

/// リフローの spine 項目内にある本文範囲の、正確な移動先。
///
/// The exact landing position of a text range in a reflowable spine item.
public struct EPUBTextRangeLanding: Sendable {
    /// 範囲の先頭を含むページの、0 始まりの番号。
    ///
    /// Zero-based page containing the beginning of the range.
    public let pageInItem: Int
    /// この範囲に対応する、正規化済みの抽出本文の一部(呼び出し元が
    /// 指定した本文)。範囲内の生の DOM テキストではない。
    ///
    /// The normalized extracted-text slice the range represents (what the
    /// caller asked for), not the raw DOM text of the range.
    public let text: String
    /// リーダービューの座標系へ変換した、範囲の各断片。
    ///
    /// Range fragments converted into the reader view's coordinate system.
    public let rects: [CGRect]
}

/// 本文の余白(NSEdgeInsets は Equatable にも Sendable にも準拠しないため、
/// 独自の型を使う)。
///
/// Content insets (a custom type because NSEdgeInsets is neither Equatable
/// nor Sendable).
public struct EPUBReaderInsets: Sendable, Equatable {
    public var top: Double
    public var left: Double
    public var bottom: Double
    public var right: Double

    public init(top: Double = 0, left: Double = 0,
                bottom: Double = 0, right: Double = 0) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }

    public static let zero = EPUBReaderInsets()
}

/// 配色テーマ。system はビューに実際に適用されている外観
/// (ライト/ダーク)に従う。
///
/// Color theme. system follows the view's effective appearance (light/dark).
public enum EPUBReaderTheme: Int, Sendable {
    case system = 0
    case light = 1
    case dark = 2
}

/// 組み込みのページめくり効果。
///
/// Built-in styles for the page-turn effect.
public enum EPUBPageTurnStyle: Sendable, Equatable {
    case none
    /// クロスフェード。
    ///
    /// Cross-fade.
    case fade
    /// 古いページを、綴じ側から離れる物理的な方向へスライドさせる。
    ///
    /// The old page slides out in the physical direction (away from the
    /// binding).
    case slide
}

/// 見開き(2 ページ)表示の方針。auto はウインドウ幅に応じて自動で切り替える
/// (Apple Books の単ページ/2 ページの判定と同じ考え方)。
///
/// Policy for two-page (spread) display. auto switches automatically based on
/// window width (the same idea as Apple Books' 1/2-page decision).
public enum EPUBColumnMode: Int, Sendable {
    case auto = 0
    case single = 1
    case double = 2
}

/// リーダー設定で使う、デバイスに依存しない sRGB 色。
///
/// A device-independent sRGB color used by reader settings.
public struct EPUBRGBAColor: Sendable, Equatable, Codable {
    /// 閉区間 `0...1` の赤成分。
    ///
    /// Red component in the closed range `0...1`.
    public var r: Double
    /// 閉区間 `0...1` の緑成分。
    ///
    /// Green component in the closed range `0...1`.
    public var g: Double
    /// 閉区間 `0...1` の青成分。
    ///
    /// Blue component in the closed range `0...1`.
    public var b: Double
    /// 閉区間 `0...1` のアルファ成分。
    ///
    /// Alpha component in the closed range `0...1`.
    public var a: Double

    /// sRGB 色を作る。各成分は `0...1` の範囲に収める。
    ///
    /// Creates an sRGB color. Components are clamped to `0...1`.
    public init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = Self.clamp(r)
        self.g = Self.clamp(g)
        self.b = Self.clamp(b)
        self.a = Self.clamp(a)
    }

    /// Core Graphics の色から sRGB 色を作る。
    ///
    /// Creates an sRGB color from a Core Graphics color.
    public init(cgColor: CGColor) {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        let converted = colorSpace.flatMap {
            cgColor.converted(to: $0, intent: .defaultIntent, options: nil)
        } ?? cgColor
        let components = converted.components ?? []
        if components.count >= 4 {
            self.init(r: Double(components[0]), g: Double(components[1]),
                      b: Double(components[2]), a: Double(components[3]))
        } else if components.count >= 2 {
            self.init(r: Double(components[0]), g: Double(components[0]),
                      b: Double(components[0]), a: Double(components[1]))
        } else {
            self.init(r: 0, g: 0, b: 0, a: 1)
        }
    }

    /// この色を CSS の `rgba()` 形式で表した文字列。
    ///
    /// A CSS `rgba()` representation of this color.
    public var cssString: String {
        "rgba(\(r * 255), \(g * 255), \(b * 255), \(a))"
    }

    private static func clamp(_ component: Double) -> Double {
        guard component.isFinite else { return 0 }
        return min(1, max(0, component))
    }
}

/// WebKit がリーダーのデリゲートへ渡すコンテキストメニューの操作を制御する。
///
/// Controls which contextual actions WebKit passes to the reader delegate.
///
/// ``EPUBReaderViewDelegate/readerView(_:willShowContextMenu:at:)`` が
/// 呼ばれる前に、WebKit のメニューをこの方針で絞り込む。デリゲートが
/// 設定されていれば、コンテキストメニューのイベントごとに必ず 1 回呼ばれる。
/// 絞り込みで項目がなくなった場合や、方針が ``suppressed`` の場合も同様。
/// デリゲートが `nil` または空のメニューを返すと表示を抑止する。
/// 空でないメニューを返せば、``suppressed`` でも表示する。
///
/// The policy filters WebKit's menu before
/// ``EPUBReaderViewDelegate/readerView(_:willShowContextMenu:at:)`` is called.
/// When a delegate is installed, it is called exactly once for every context-menu
/// event, including when filtering leaves no items and when the policy is
/// ``suppressed``. A delegate return value of `nil` or an empty menu suppresses
/// presentation. A non-empty returned menu is presented even under ``suppressed``.
public enum EPUBContextMenuPolicy: Sendable, Equatable {
    /// WebKit のシステムメニューをすべて使う。
    ///
    /// Uses WebKit's complete system menu.
    case system
    /// デリゲートによるカスタマイズの前に、WebKit が用意した項目をすべて除く。
    ///
    /// Removes every WebKit-provided item before delegate customization.
    case suppressed
    /// 識別子の raw value が許可されているメニュー項目だけを残す。
    ///
    /// Keeps only menu items whose identifier raw values are allowed.
    case allowing(identifiers: Set<String>)

    /// 読書向けのメニュー。利用可能な場合に、調べる、翻訳、コピー、
    /// Web 検索、読み上げの操作を含む。
    ///
    /// A reading-oriented menu containing lookup, translation, copy, web
    /// search, and speech actions when those actions are available.
    public static let readingDefault: EPUBContextMenuPolicy = .allowing(
        identifiers: [
            "WKMenuItemIdentifierLookUp",
            "WKMenuItemIdentifierTranslate",
            "WKMenuItemIdentifierCopy",
            "WKMenuItemIdentifierSearchWeb",
            "WKMenuItemIdentifierSpeechMenu",
        ])
}

extension EPUBContextMenuPolicy {
    /// cooViewer-oxr.35: WebKit が組み立てた menu を identifier だけで絞る。
    /// 許可済み submenu は中身を保ち、識別子のない wrapper は許可された子が
    /// 残る場合だけ保持する。
    @MainActor
    func filter(_ menu: NSMenu) -> Bool {
        switch self {
        case .system:
            return !menu.items.isEmpty
        case .suppressed:
            menu.removeAllItems()
            return false
        case .allowing(let identifiers):
            filter(menu, identifiers: identifiers)
            trimSeparators(in: menu)
            return !menu.items.isEmpty
        }
    }

    @MainActor
    private func filter(_ menu: NSMenu, identifiers: Set<String>) {
        for item in menu.items.reversed() {
            if item.isSeparatorItem { continue }
            if let identifier = item.identifier?.rawValue,
               identifiers.contains(identifier) {
                continue
            }
            if let submenu = item.submenu {
                filter(submenu, identifiers: identifiers)
                trimSeparators(in: submenu)
                if !submenu.items.isEmpty { continue }
            }
            menu.removeItem(item)
        }
    }

    @MainActor
    private func trimSeparators(in menu: NSMenu) {
        var previousWasSeparator = true
        for item in menu.items {
            if item.isSeparatorItem {
                if previousWasSeparator { menu.removeItem(item) }
                previousWasSeparator = true
            } else {
                previousWasSeparator = false
            }
        }
        if let last = menu.items.last, last.isSeparatorItem {
            menu.removeItem(last)
        }
    }
}

/// リーダーの表示設定。
///
/// Reader display settings.
public struct EPUBReaderSettings: Sendable, Equatable {
    /// ページ割り時に、本のルート要素の計算済みフォントサイズへ掛ける基準倍率。
    /// 有効範囲は EPUBReaderView.fontScaleRange(0.5 〜 3.0)。
    ///
    /// Base font-size multiplier applied to the book's computed root font size
    /// during pagination. The valid range is EPUBReaderView.fontScaleRange
    /// (0.5 to 3.0).
    public var fontScale: Double = 1.0
    /// ページ間の隙間(px 単位)。隣のページの字形がはみ出して見えるのを防ぐ。
    /// 0 でも動作する。
    ///
    /// Gap between pages in px (prevents glyphs from the adjacent page
    /// bleeding through; 0 still works).
    public var pageGap: Double = 24
    /// 本文の余白。WKWebView 自体を内側へ配置し、段組みの座標系を単純に保つ。
    /// 余白はネイティブの背景色で塗り、各ページのノンブル(ページ番号)を
    /// 下余白に置く。Apple Books の版面設計に倣ったもの。
    /// 固定レイアウト(FXL)のページには適用せず、余白なしで全面に表示する。
    ///
    /// Content insets. The WKWebView itself is inset, keeping the multicol
    /// coordinate system simple. The margins are painted as the native
    /// background, and each page's folio (page number) sits in the bottom
    /// margin — mirroring Apple Books' page-layout design. Not applied to
    /// fixed-layout (FXL) pages (which display full-bleed).
    ///
    /// 単ページ表示の基準値で、見開き表示の既定値にもなる。
    /// 見開き(2 ページ)に別の余白を使う場合は ``spreadInsets`` を設定する。
    ///
    /// This is the base value, used for single-page display and as the default
    /// for spread display; set ``spreadInsets`` to give the spread (two-up)
    /// layout different margins.
    public var insets = EPUBReaderInsets(top: 56, left: 56, bottom: 52, right: 56)
    /// 見開き(2 ページ)表示で使う本文の余白。nil(既定)なら ``insets`` を使う。
    /// 大きなウインドウで外側の余白を広げるなど、見開き専用の余白を指定できる。
    /// 2 ページの間のノドの幅は、この余白に加えて自動で確保する。
    ///
    /// Content insets used in spread (two-up) display. When nil (the default),
    /// spread display uses ``insets``. Set it to give the two-page layout its
    /// own margins — e.g. wider outer margins on a large window. The center
    /// gutter between the two pages is added automatically on top of these.
    public var spreadInsets: EPUBReaderInsets?
    /// 見開き表示の方針(既定はウインドウ幅に応じた自動切替)。
    ///
    /// Spread-display policy (default: automatic, based on window width).
    public var columnMode: EPUBColumnMode = .auto
    /// 配色テーマ(既定はシステムの外観に従う)。
    ///
    /// Color theme (default: follows the system appearance).
    public var theme: EPUBReaderTheme = .system
    /// 各ページの下余白の中央にノンブル(ページ番号)を表示するか。
    ///
    /// Whether to show the folio (page number) centered in each page's bottom
    /// margin.
    public var showsPageFurniture = true
    /// ページめくり効果。「視差効果を減らす」が有効な場合や、素早い連続押下では
    /// 自動で省略する。デリゲートの animatePageTurn で、ページカールなど
    /// ホスト独自の効果へ差し替えられる。
    ///
    /// The page-turn effect (automatically skipped when "Reduce Motion" is on
    /// and during rapid repeated presses). The delegate's animatePageTurn can
    /// replace it with a host-specific effect (page curl, etc.).
    public var pageTurnStyle: EPUBPageTurnStyle = .slide
    /// ピンチ操作でフォント倍率を変更するか。無効でも adjustFontScale(by:) と
    /// settings.fontScale の直接設定は使える。
    ///
    /// Whether pinch gestures change the font multiplier (even when off,
    /// adjustFontScale(by:) and directly setting settings.fontScale still
    /// work).
    public var pinchAdjustsFontScale = true
    /// 本が font-family を指定していない場合の既定フォント(CSS のファミリー名。
    /// nil は WebKit の既定値)。html 要素に !important なしで注入するため、
    /// 本自身の指定(EBPAJ / 電書協テンプレートなど)が常に優先される。
    ///
    /// Default font used when the book does not specify a font-family (a CSS
    /// family name; nil = WebKit default). Injected at the html level without
    /// !important, so the book's own declarations (e.g. the EBPAJ / 電書協
    /// template) always win.
    public var defaultFontFamily: String?
    /// 行高を調整するおおよその倍率。CSS では著者が指定した計算済みの行高を
    /// 常に再利用できる値として取り出せないため、Washi は代替値 `1.6` に
    /// この倍率を掛ける。
    ///
    /// Approximate multiplier for line height. Washi applies the multiplier to
    /// a `1.6` fallback because CSS cannot recover every authored computed
    /// line-height as a reusable value.
    public var lineHeightScale: Double?
    /// 追加の字間(em 単位)。Readium CSS の CJK 本文向けの指針に従い、
    /// 縦書きでは意図的に無視する。
    ///
    /// Additional letter spacing in em. It is intentionally ignored in
    /// vertical writing, following Readium CSS guidance for CJK content.
    public var letterSpacingEm: Double?
    /// 段落のブロック末尾の間隔(em 単位)。
    ///
    /// Paragraph block-end spacing in em.
    public var paragraphSpacingEm: Double?
    /// コード用などの要素を除き、著者指定のフォントを上書きするファミリー名。
    ///
    /// Font family that overrides authored fonts except in code-like elements.
    public var fontFamilyOverride: String?
    /// ルビと、ルビ非対応時の代替表示用の括弧をレイアウトから除くか。
    /// 既定は false。
    ///
    /// Whether ruby annotations and fallback parentheses are removed from
    /// layout. Default is false.
    public var hidesRuby = false
    /// ページ背景の CSS 色(nil はテーマの既定色)。
    ///
    /// Page background CSS color (nil = theme default).
    public var backgroundColorCSS: String?
    /// 専用の型で指定するページ背景色。設定すると、Web 本文とネイティブの余白の
    /// 両方で ``backgroundColorCSS`` より優先される。
    ///
    /// Typed page background color. When set, this takes precedence over
    /// ``backgroundColorCSS`` for both web content and native margins.
    public var backgroundColor: EPUBRGBAColor?
    /// 本文文字の CSS 色(nil はテーマの既定色)。
    ///
    /// Body text CSS color (nil = theme default).
    public var textColorCSS: String?
    /// 専用の型で指定する本文文字色。設定すると ``textColorCSS`` より優先される。
    ///
    /// Typed body text color. When set, this takes precedence over
    /// ``textColorCSS``.
    public var textColor: EPUBRGBAColor?
    /// true なら、本文にテーマの文字色を強制する。「読みやすさ優先」モード
    /// として、本自身の色指定を `!important` で上書きし、テーマの背景に対して
    /// 読める色を保つ。false(既定)は本の配色を尊重するモードで、本の色を優先し、
    /// テーマは代替色だけを補う。ホストが ``textColor`` または ``textColorCSS``
    /// で色を明示している場合は無視する。本が意図した配色や、明るい背景の
    /// 囲み記事のコントラストが失われる場合があるため、ユーザーが選べる設定にする。
    ///
    /// When true, the reader forces its theme's text color onto the book's
    /// content, overriding the book's own color declarations (via `!important`),
    /// so pages stay legible against the themed background — the "prioritize
    /// readability" mode. When false (default), the book's own colors win and
    /// the theme only supplies a fallback (respect-the-book mode). Ignored when
    /// ``textColor`` or ``textColorCSS`` supplies an explicit host color.
    /// Trade-off: a book's intentional colors and light-background call-outs
    /// may lose contrast, so expose it as a user choice.
    public var forcesReadableColors = false
    /// EPUB の脚注・後注の aside 要素を、ページ割りされる本文から隠すか。
    /// ホストは noteref を捕捉し、代わりに ``EPUBNoteContent`` を
    /// ポップオーバーで表示できる。既定は false。
    ///
    /// Whether EPUB footnote and endnote asides are hidden from the paginated
    /// flow. Hosts can intercept a noteref and present ``EPUBNoteContent`` in
    /// a popover instead. Default is false.
    public var hidesFootnoteAsides = false
    /// ダークテーマで、字形に見える小さなインライン画像を反転するか。
    ///
    /// Whether dark themes invert small inline images that look like glyphs.
    ///
    /// 一般的な `gaiji`、`kigou`、`glyph` クラスに加え、表示サイズが周囲の
    /// 文字に近い小さなインライン画像を検出する。図や画像 1 枚だけのページは
    /// 意図的に対象から外すが、小さな挿絵を誤判定することはある。
    /// 出版物で画像本来の色を保つ必要がある場合は false にする。既定は true。
    ///
    /// Washi recognizes common `gaiji`, `kigou`, and `glyph` classes, plus
    /// small inline images whose rendered size is close to the surrounding
    /// text. The heuristic intentionally excludes figures and single-image
    /// pages, but a small illustration can still be misclassified; set this
    /// to false when a publication needs its original image colors. Default
    /// is true.
    public var invertsGlyphImagesInDark = true
    /// 追加のユーザー CSS(最後に注入する)。
    ///
    /// Additional user CSS (injected last).
    public var userCSS: String?
    /// true なら、矢印やスペースなどの既定のキー操作をビュー内で処理する。
    /// false ならキーをデリゲートへ転送し、ホストのキーバインドを優先する。
    ///
    /// When true, default key actions (arrows, space, etc.) are handled within
    /// the view. When false, keys are forwarded to the delegate (giving the
    /// host's key bindings priority).
    public var handlesKeyboardNavigation = true
    /// true ならネイティブのキーモニターを設置し、埋め込みの `WKWebView` が
    /// キーを消費する前に、各キー押下の `NSEvent` を
    /// `readerView(_:didReceiveNativeKey:)` へ転送する。独自のキーバインドを
    /// 持つホストが、WebKit の処理前に `NSEvent` を確実に順序どおり受け取る
    /// 必要がある場合、JS 経由の `didReceiveKey` の代わりに使う(JS 経由では
    /// DOM のキー識別情報を非同期に届ける)。`handlesKeyboardNavigation` とは
    /// 独立している。既定は false。このリーダーまたは埋め込みの Web 本文に
    /// キーボードフォーカスがある間だけ適用する。WebKit が再送したイベントも
    /// 含め、各イベントは 1 回だけ届ける。
    ///
    /// When true, the view installs a native key monitor and forwards each
    /// `NSEvent` key-down to `readerView(_:didReceiveNativeKey:)` before the
    /// embedded `WKWebView` can consume it. Use this instead of the JS-based
    /// `didReceiveKey` path when the host has its own key bindings and needs
    /// reliable, in-order `NSEvent`s before WebKit handles them (the JS path
    /// delivers DOM key identities asynchronously). Independent of
    /// `handlesKeyboardNavigation`. Default false.
    /// Applies only while this reader or its embedded web content has keyboard
    /// focus. Each event is delivered once, including events resent by WebKit.
    public var forwardsKeyEventsNatively = false
    /// メディアオーバーレイのナレーション再生速度(1.0 は録音時の速度)。
    /// AVAudioPlayer で明瞭に再生できる範囲の 0.5 〜 3.0 に収める。
    ///
    /// Playback rate for media-overlay narration (1.0 = the recorded speed).
    /// Clamped to 0.5…3.0, the range AVAudioPlayer reproduces intelligibly.
    public var mediaOverlayPlaybackRate: Double = 1.0
    /// メディアオーバーレイの再生時にクリップをスキップする `epub:type` の値
    /// (EPUB Reading Systems 3.3 §9.4.1 skippability)。代表例は
    /// "pagebreak"、"footnote"、"noteref"、"annotation"。
    /// 既定は空で、すべて再生する。
    ///
    /// `epub:type` values whose media-overlay clips are skipped during playback
    /// (EPUB Reading Systems 3.3 §9.4.1 skippability). Typical values are
    /// "pagebreak", "footnote", "noteref" and "annotation". Empty by default,
    /// which plays everything.
    public var mediaOverlaySkippedTypes: Set<String> = []
    /// スクリプト付きコンテンツ(本の JavaScript)を許可するか。既定は false。
    ///
    /// Whether to allow scripted content (the book's JavaScript). Default
    /// false.
    public var allowsScriptedContent = false
    /// コンテキストメニューの方針。system 以外の方針と従来の
    /// ``suppressesContextMenu`` スイッチを両方設定した場合は、
    /// この方針を優先する。
    ///
    /// Context-menu policy. A non-system policy takes precedence over the
    /// legacy ``suppressesContextMenu`` switch when both are configured.
    public var contextMenuPolicy: EPUBContextMenuPolicy = .system
    /// true なら、右クリックや control クリックで Web ビューの
    /// コンテキストメニューを開かず、ホストが独自のメニューを提供できる。
    /// 既定は false。``contextMenuPolicy`` が ``EPUBContextMenuPolicy/system``
    /// の間は、``EPUBContextMenuPolicy/suppressed`` として扱う。
    ///
    /// When true, right-click (and control-click) does not open the web view's
    /// context menu, so the host can provide its own. Default false. This is
    /// treated as ``EPUBContextMenuPolicy/suppressed`` while
    /// ``contextMenuPolicy`` is ``EPUBContextMenuPolicy/system``.
    public var suppressesContextMenu = false
    /// VoiceOver の使用中、ページの移動が確定したら読み上げて知らせるか。
    /// 既定は true。
    ///
    /// Whether settled page changes are announced while VoiceOver is active.
    /// Default is true.
    public var announcesPageChanges = true
    /// ネイティブのノンブル表示に、現在の印刷ページのラベルを付け加えるか。
    /// 既定は false。
    ///
    /// Whether the current print page label is appended to native page
    /// furniture. Default is false.
    public var showsPrintPageInFurniture = false
    /// true なら、システムのダブルクリック判定時間が過ぎてから主ボタンの
    /// クリックを通知する。単語を選ぶダブルクリックで先にページがめくられるのを
    /// 防ぐが、タップごとにその時間分の遅延が生じる。
    ///
    /// When true, a primary click is reported only after the system
    /// double-click interval so a double-click that selects a word never turns
    /// the page first; costs that much latency per tap.
    public var defersTapsForDoubleClick = false
    /// true(既定)なら、トラックパッドやホイールの横操作で 1 ページめくる。
    /// ホスト自身が横スワイプによるページめくりを処理する場合は false にして、
    /// 二重実行を防ぎ、ホストの「スワイプでページをめくる」設定を尊重する。
    /// どちらの場合も、ページ割りされた本文の縦方向のホイールスクロールには
    /// 影響しない。
    ///
    /// When true (default), a horizontal trackpad/wheel gesture turns one page.
    /// Set false when the host drives horizontal swipe page-turns itself (so the
    /// two do not both fire, and the host's "swipe turns pages" preference is
    /// honored). Vertical wheel scrolling through paginated content is
    /// unaffected either way.
    public var horizontalWheelTurnsPages = true
    /// トラックパッドやホイールの横操作によるページめくりの方向を反転する。
    /// 既定では左向きの操作で左側のページへめくる(本の組み方向に応じて
    /// 物理方向へ対応づける)。ホストは独自のスワイプ方向の設定にホイール操作を
    /// そろえるために使う。複数巻をまとめたコレクションで個々の巻と読む順序が
    /// 異なる場合にも、コレクションの方向にそろえられる。既定は false。
    ///
    /// Inverts the reading direction of horizontal trackpad/wheel page turns.
    /// By default a leftward gesture turns toward the left-hand page (physical
    /// mapping via the book's writing direction). The host sets this to align
    /// wheel turns with its own swipe-direction preference and, in a merged
    /// collection whose reading order differs from an individual volume, with
    /// the collection's direction. Default false.
    public var reversesHorizontalWheelTurn = false

    public init() {}

    /// テーマの実効配色(ライト = 紙白、ダーク = Apple Books 系の
    /// ほぼ黒 + 明灰文字)。明示指定(backgroundColorCSS 等)が最優先
    func effectiveColors(
        isDark: Bool, increaseContrast: Bool = false
    ) -> (background: String, text: String?) {
        if increaseContrast {
            // cooViewer-oxr.37: システムのコントラスト増加時は著者・host の
            // 中間色より純黒/純白を優先し、背景と本文を同じ経路で決める。
            return isDark ? ("#000000", "#ffffff")
                          : ("#ffffff", "#000000")
        }
        let background = backgroundColor?.cssString
            ?? backgroundColorCSS ?? (isDark ? "#1a1a1c" : "#ffffff")
        let text: String?
        if let explicit = textColor?.cssString ?? textColorCSS {
            text = explicit
        } else if forcesReadableColors {
            // 読みやすさ優先: 本が色を指定していても、テーマ背景に対して確実に
            // 読める文字色を両モードで用意する(Apple Books のダーク相当)
            text = isDark ? "#ececec" : "#1a1a1a"
        } else {
            // 本の配色を尊重: ダークだけ継承用の明灰を用意(本が色指定を持つ
            // ページはそちらが勝つ=本来の見た目のまま)
            text = isDark ? "#d5d5d0" : nil
        }
        return (background, text)
    }

    /// CSS-string escaping shared by the default and overriding font settings.
    private func escapedFontFamily(_ family: String) -> String {
        let stripped = family.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
                && $0 != "\u{2028}" && $0 != "\u{2029}"
        }
        return String(String.UnicodeScalarView(stripped))
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// fontScale を CSS で上書きせず census/layout key だけへ反映する印。
    /// 実倍率は cooViewer-oxr.60 / cooViewer-oxr.76 の runtime 計測で適用する。
    private func fontScaleKeyCSS() -> String {
        guard fontScale != 1.0 else { return "" }
        return "/* washi-font-scale: \(fontScale) */\n"
    }

    /// cooViewer-oxr.32: namespace 宣言は同じ stylesheet の全規則より前に置く。
    /// aside の非表示は本文量を変えるため、注入 CSS と census key で共用する。
    private func footnoteVisibilityCSS() -> String {
        guard hidesFootnoteAsides else { return "" }
        return """
        @namespace epub url(http://www.idpf.org/2007/ops);
        aside[epub|type~="footnote"], aside[epub|type~="endnote"], aside[epub|type~="rearnote"], aside[role="doc-footnote"], aside[role="doc-endnote"] { display: none !important; }

        """
    }

    /// 著者 stylesheet より前へ挿入する既定フォント CSS。
    /// 最初の cascade layer + :where の詳細度 0 で、cooViewer-oxr.77 の
    /// 「本が常に勝つ」を layered stylesheet に対しても守る。
    func defaultFontCSS() -> String {
        var css = ""
        if let family = defaultFontFamily, !family.isEmpty {
            // !important なし + :where(html) = 継承でしか効かないため、
            // 「本が指定しなかったときだけ」の既定フォントになる。
            // 値は CSS 文字列としてエスケープ(defaults 直書きの任意文字列で
            // 規則が壊れたり CSS が注入されたりしないように)。改行・制御文字は
            // CSS 文字列トークンを終端させ後続を新規規則として注入できてしまう
            // ため、エスケープ前に除去する(U+2028/2029 は controlCharacters に
            // 含まれないので明示除去。CJK フォント名を通すため allowlist は使わない)
            let escaped = escapedFontFamily(family)
            css += "@layer washi-reader-default { :where(html) { font-family: \"\(escaped)\", serif; } }\n"
        }
        return css
    }

    /// cooViewer-oxr.33: 文字組み設定はすべて本文量または字送りを変えるため、
    /// live CSS と census key が同じ文字列を共有する。
    private func typographyCSS() -> String {
        var css = ""
        if let scale = lineHeightScale, scale.isFinite, scale > 0 {
            css += "html { --washi-line-height-scale: \(scale); }\n"
            css += "body * { line-height: calc(var(--washi-line-height-base, 1.6) * var(--washi-line-height-scale)) !important; }\n"
        }
        if let spacing = letterSpacingEm, spacing.isFinite {
            // cooViewer-oxr.33: 縦組みでは字間・単語間を強制しない。
            css += "html:not(.washi-vertical) body, html:not(.washi-vertical) body * { letter-spacing: \(spacing)em !important; }\n"
        }
        if let spacing = paragraphSpacingEm, spacing.isFinite {
            css += "p { margin-block-end: \(spacing)em !important; }\n"
        }
        if let family = fontFamilyOverride, !family.isEmpty {
            let escaped = escapedFontFamily(family)
            css += "body, body *:not(code):not(pre):not(kbd):not(samp) { font-family: \"\(escaped)\", serif !important; }\n"
        }
        if hidesRuby {
            css += "rt, rp { display: none !important; }\n"
        }
        return css
    }

    /// ページ割りに影響する CSS だけを組み立てる(census 用。
    /// 配色はページ数に影響しないため含めない — テーマ切替で census を
    /// 無駄に無効化しないためのキー安定化)
    func layoutAffectingCSS() -> String {
        footnoteVisibilityCSS() + fontScaleKeyCSS() + typographyCSS()
            + (userCSS ?? "")
    }

    /// 注入するユーザー CSS を組み立てる
    func composedUserCSS(
        isDark: Bool, increaseContrast: Bool = false,
        differentiateWithoutColor: Bool = false
    ) -> String {
        var css = footnoteVisibilityCSS() + fontScaleKeyCSS() + typographyCSS()
        let colors = effectiveColors(
            isDark: isDark, increaseContrast: increaseContrast)
        css += ":root { color-scheme: \(isDark ? "dark" : "light"); }\n"
        css += "html { background-color: \(colors.background) !important; }\n"
        // cooViewer-oxr.4: ダークでは本の body の白背景でテーマの地色を覆わない。
        // 本の配色を尊重するライトでは、クリーム色など本来の body 背景を保つ。
        // 読みやすさ優先では両テーマで子孫の不透明背景も除くが、画像等の背景は保つ。
        let readable = increaseContrast
            || (forcesReadableColors && textColor == nil && textColorCSS == nil)
        if readable {
            css += "body, body *:not(img):not(svg):not(image):not(video):not(canvas) { background-color: transparent !important; }\n"
            if isDark {
                // cooViewer-oxr.4: 透明化規則の :not による詳細度も上回る必要がある。
                css += "body :is(pre, code):not(img):not(svg):not(image):not(video):not(canvas) { background-color: #242426 !important; }\n"
            }
        } else if isDark {
            css += "body { background-color: transparent !important; }\n"
        }
        if let text = colors.text {
            if readable {
                // 読みやすさ優先: 本の色指定(class・要素セレクタ等)より強く
                // 上書きして必ず読める色に(!important で継承の壁を越える)。
                // cooViewer-oxr.4: リンクの span/ruby とコードの子孫も除外し、
                // リンクの継承色・コード固有の配色を保つ。
                css += "body, body *:not(a):not(a *):not(pre):not(code):not(pre *):not(code *) { color: \(text) !important; }\n"
                css += "a { color: \(isDark ? "#7fb2ff" : "#1a56db") !important; }\n"
            } else {
                // 本の配色を尊重: body への継承指定のみ(本文が色指定を持つ本は
                // そちらが勝つ)。リンクはダークで読める青へ
                css += "body { color: \(text); }\n"
                if isDark {
                    css += "a { color: #7fb2ff; }\n"
                }
            }
        }
        if isDark {
            // cooViewer-oxr.78: 写真や挿絵を反転せず、JS が字形と判定した
            // 小さなインライン画像だけを対象にする。filter は配色だけを変え、
            // 版面寸法には影響しない。
            if invertsGlyphImagesInDark {
                css += "img.washi-glyph { filter: invert(1) !important; }\n"
            }
            // cooViewer-oxr.78: fill 未指定の最外 SVG だけを currentColor へ
            // 揃え、子孫へ継承させる。子要素へ直接指定すると祖先の fill="none"
            // や明示色を上書きするため、入れ子 SVG も祖先色をそのまま継承する。
            let strength = readable ? " !important" : ""
            css += ":where(svg:not(svg *):not([fill]):not([style*=\"fill\" i])) { fill: currentColor\(strength); }\n"
            css += ":where(svg:is([stroke=\"black\" i], [stroke=\"#000\" i], [stroke=\"#000000\" i]), svg :is([stroke=\"black\" i], [stroke=\"#000\" i], [stroke=\"#000000\" i])) { stroke: currentColor\(strength); }\n"
        }
        if differentiateWithoutColor {
            // cooViewer-oxr.37: 色だけに依存せずリンクを識別できるようにする。
            css += "a { text-decoration: underline !important; }\n"
        }
        if let extra = userCSS {
            css += extra
        }
        return css
    }
}

/// 1 つの spine 項目の、正規化済み UTF-16 テキストマップにおける本文選択。
///
/// A text selection in the normalized UTF-16 text map of one spine item.
public struct EPUBTextSelection: Sendable, Equatable {
    /// 選択範囲を含む spine 項目の、読む順序でのインデックス。
    ///
    /// Reading-order spine index containing the selection.
    public let spineIndex: Int
    /// 選択された正規化済みの本文。
    ///
    /// Selected normalized text.
    public let text: String
    /// 正規化済み本文の選択範囲(UTF-16 コード単位)。
    ///
    /// Selected range in normalized UTF-16 code units.
    public let utf16Range: Range<Int>
    /// リーダービューの座標系で表した、選択範囲の各断片。
    ///
    /// Selection fragments in reader-view coordinates.
    public let rects: [CGRect]

    public init(spineIndex: Int, text: String, utf16Range: Range<Int>,
                rects: [CGRect]) {
        self.spineIndex = spineIndex
        self.text = text
        self.utf16Range = utf16Range
        self.rects = rects
    }
}

/// handlesKeyboardNavigation が false のときにホストへ転送するキーイベント。
///
/// A key event forwarded to the host (when handlesKeyboardNavigation is
/// false).
public struct EPUBKeyEvent: Sendable, Equatable {
    public let key: String
    public let code: String
    public let shift: Bool
    public let option: Bool
    public let control: Bool
    public let command: Bool
}

/// ページ面でのクリックの詳細(デリゲートへ転送する)。button は NSEvent と
/// 同じ番号を使う(0 = 左、1 = 右、2 = 中央、3/4 = サイド)。右クリックは通常の
/// `didClick` コールバックには送らず、コンテキストメニューのデリゲート
/// コールバックへ渡すイベントとして表す。
///
/// Details of a click on the page surface (forwarded to the delegate).
/// button uses NSEvent-style numbering (0 = left, 1 = right, 2 = middle,
/// 3/4 = side). Right-clicks are not sent through the regular `didClick`
/// callback; they are represented by the event passed to the context-menu
/// delegate callback instead.
public struct EPUBClickEvent: Sendable, Equatable {
    /// 0..1 に正規化した座標。
    ///
    /// Normalized coordinates in 0..1.
    public let x: Double
    public let y: Double
    /// リーダービューの座標系でのクリック位置。
    ///
    /// Click location in the coordinate system of the reader view.
    public let locationInView: CGPoint
    public let button: Int
    public let shift: Bool
    public let option: Bool
    public let control: Bool
    public let command: Bool

    public init(x: Double, y: Double, locationInView: CGPoint,
                button: Int, shift: Bool, option: Bool,
                control: Bool, command: Bool) {
        self.x = x
        self.y = y
        self.locationInView = locationInView
        self.button = button
        self.shift = shift
        self.option = option
        self.control = control
        self.command = command
    }

    /// 修飾キーなしの左クリックか(既定の端タップによるページめくりの対象)。
    ///
    /// Whether this is a left click with no modifier keys (the target of the
    /// default edge-tap page turn).
    public var isPlainPrimary: Bool {
        button == 0 && !shift && !option && !control && !command
    }
}

/// EPUB の読む順序に含まれる文書から、同じ出版物内の別の位置への
/// 解決済みリンク。
///
/// A resolved link from one EPUB reading-order document to another location
/// in the same publication.
public struct EPUBInternalLink: Sendable, Equatable {
    /// 出版物に記載されたとおりの href。
    ///
    /// The href exactly as declared by the publication.
    public let href: String
    /// 現在の文書を基準に解決した、正規化済みのコンテナパス。
    ///
    /// The canonical container path resolved relative to the current document.
    public let containerPath: String
    /// フラグメント識別子がある場合、そのデコード済みの値。
    ///
    /// The decoded fragment identifier, when present.
    public let fragment: String?
    /// リンク先が読む順序に含まれる場合、その出版物内でのインデックス。
    ///
    /// The destination's index in the publication reading order, when present.
    public let targetSpineIndex: Int?
    /// クリックしたアンカーの `epub:type` の値。
    ///
    /// The clicked anchor's `epub:type` value.
    public let epubType: String?
    /// クリックしたアンカーの ARIA ロール。
    ///
    /// The clicked anchor's ARIA role.
    public let role: String?
    /// アンカーが EPUB または ARIA の注への参照か。
    ///
    /// Whether the anchor is an EPUB or ARIA note reference.
    public let isNoteReference: Bool
    /// 同じ文書内にあるリンク先の注に、このアンカーへ戻るリンクが含まれるか。
    ///
    /// Whether a same-document note target contains a link back to the anchor.
    public let hasBacklink: Bool
    /// 同じ文書内のリンク先に `epub:type` がある場合、その値。
    ///
    /// The same-document target's `epub:type` value, when available.
    public let targetEpubType: String?
    /// リーダービューの座標系で表した、クリックしたアンカーの境界矩形。
    ///
    /// The clicked anchor's bounds in the reader view's coordinate system.
    public let anchorRect: CGRect?

    public init(
        href: String,
        containerPath: String,
        fragment: String?,
        targetSpineIndex: Int?,
        epubType: String?,
        role: String?,
        isNoteReference: Bool,
        hasBacklink: Bool,
        targetEpubType: String?,
        anchorRect: CGRect?
    ) {
        self.href = href
        self.containerPath = containerPath
        self.fragment = fragment
        self.targetSpineIndex = targetSpineIndex
        self.epubType = epubType
        self.role = role
        self.isNoteReference = isNoteReference
        self.hasBacklink = hasBacklink
        self.targetEpubType = targetEpubType
        self.anchorRect = anchorRect
    }
}

/// EPUB の注の参照先から抽出した本文と、取得できる場合はそのマークアップ。
///
/// Text and optional markup extracted from an EPUB note target.
public struct EPUBNoteContent: Sendable, Equatable {
    /// 戻りリンクのアンカーを除いた、人が読める形式の注の本文。
    ///
    /// Human-readable note text with backlink anchors removed.
    public let text: String
    /// 現在表示中の文書内の注から、戻りリンクのアンカーを除いた内部 HTML。
    /// 別の文書からは画面表示なしで抽出するため、この値は nil になる。
    ///
    /// Inner HTML with backlink anchors removed for a note in the currently
    /// displayed document. Cross-document extraction is headless and returns
    /// nil here.
    public let html: String?
    /// 注を含む文書の、読む順序でのインデックス。
    ///
    /// Index of the document containing the note in the reading order.
    public let sourceSpineIndex: Int

    public init(text: String, html: String?, sourceSpineIndex: Int) {
        self.text = text
        self.html = html
        self.sourceSpineIndex = sourceSpineIndex
    }
}

/// リーダービューのイベント通知の受け取り先。
///
/// Receiver of the reader view's event notifications.
@MainActor
public protocol EPUBReaderViewDelegate: AnyObject {
    /// 表示位置が変わった(ページめくり、章の移動、または位置の復元)。
    ///
    /// The displayed position changed (page turn, chapter move, or restore).
    func readerView(_ view: EPUBReaderView, didMoveTo locator: EPUBLocator,
                    pageInItem: Int, pageCountInItem: Int)
    /// 本の先頭または末尾を越えて移動しようとした(forward = true は末尾側)。
    ///
    /// An attempt to move past the start/end of the book (forward = true is
    /// the end side).
    func readerView(_ view: EPUBReaderView, didReachBookEdge forward: Bool)
    /// 外部リンクを開く直前の通知。既定の動作(ブラウザで開く)を使う場合は
    /// true を返す。
    ///
    /// About to open an external link. Return true for the default action
    /// (open in the browser).
    func readerView(_ view: EPUBReaderView, shouldOpenExternalURL url: URL) -> Bool
    /// 解決済みの EPUB 内部リンクに、リーダーの既定の移動処理を使うかを尋ねる。
    /// 注を表示したりホスト自身で処理したりする場合は false を返す。
    ///
    /// Asks whether a resolved internal EPUB link should use the reader's
    /// default navigation. Return false to show a note or handle it yourself.
    func readerView(_ view: EPUBReaderView,
                    shouldFollowInternalLink link: EPUBInternalLink) -> Bool
    /// handlesKeyboardNavigation が false のときに使う、キーの転送。
    ///
    /// Key forwarding, used when handlesKeyboardNavigation is false.
    func readerView(_ view: EPUBReaderView, didReceiveKey event: EPUBKeyEvent)
    /// `didReceiveKey` へ渡した直後のキーを、リーダービューで消費するか尋ねる。
    /// false を返すと元のイベントがレスポンダーチェーンを上へ伝わり、ホストが
    /// 処理しないキー(`-`、Esc、`+` など)もウインドウやメニューバーに届く。
    /// 既定は true で、Washi 1.16.x 以前と同じく、キーはここで止まる。
    ///
    /// Asks whether the key just delivered to `didReceiveKey` stops at the
    /// reader view. Return false to let the original event continue up the
    /// responder chain, so keys the host does not handle (`-`, Esc, `+`, …)
    /// still reach the window and the menu bar. Default: true, which keeps the
    /// behaviour of Washi 1.16.x and earlier (the key stops here).
    ///
    /// 同じキーの `didReceiveKey` の直後に呼ぶため、ホストはそこで処理したかを
    /// 記録し、その結果を返すだけでよい。`didReceiveKey` でフラグを設定し、
    /// このメソッドでその値を返す。
    ///
    /// Called right after `didReceiveKey` for the same key, so a host can
    /// record what it handled there and simply report it back:
    /// `didReceiveKey` sets a flag, this method returns it.
    ///
    /// リーダービュー自身が受け取ったキーだけが対象。Web ビューがファースト
    /// レスポンダーの間に入力されたキーをページが処理しなかった場合、
    /// WebKit がレスポンダーチェーンへ再送するため、このメソッドの戻り値に
    /// 関係なく伝播する。
    ///
    /// Only consulted for keys the reader view itself receives. Keys typed
    /// while the web view holds first responder are resent to the responder
    /// chain by WebKit when the page leaves them unhandled, so they propagate
    /// regardless of what this method returns.
    func readerView(_ view: EPUBReaderView,
                    shouldConsumeKey event: EPUBKeyEvent) -> Bool
    /// `EPUBReaderSettings.forwardsKeyEventsNatively` が true の場合だけ届く、
    /// ネイティブのキー押下イベント。true を返すとイベントを消費し、
    /// Web ビューには届かない。false を返すと通常どおり伝播する。
    /// 実際の `NSEvent` が順序どおりに届き、Web ビューがファーストレスポンダー
    /// でも受け取れるため、独自のキーバインドを持つホストには `didReceiveKey`
    /// よりこちらが適している。
    /// 同じウインドウ内の別のコントロールへのイベントは捕捉しない。未処理の
    /// イベントを WebKit が再送しても、このメソッドは再度呼ばれない。
    ///
    /// A native key-down event, delivered only when
    /// `EPUBReaderSettings.forwardsKeyEventsNatively` is true. Return true to
    /// consume the event (the web view never sees it); return false to let it
    /// propagate normally. Preferred over `didReceiveKey` for hosts with their
    /// own key bindings — it is a real `NSEvent`, in order, and reaches you even
    /// while the web view holds first responder.
    /// Events for other controls in the same window are not intercepted, and
    /// WebKit's resend of an unhandled event does not call this method again.
    ///
    /// モニターはレスポンダーチェーンより先に動くため、true を返すとその
    /// イベントによるメニューのショートカット(⌘C、⌘W など)も抑止する。
    /// ホストが実際に処理するキーだけ true を返し、それ以外は false を返す。
    ///
    /// The monitor runs before the responder chain, so returning true also
    /// suppresses menu key equivalents (⌘C, ⌘W, …) for that event. Return true
    /// only for keys your host actually handles; return false for the rest.
    func readerView(_ view: EPUBReaderView,
                    didReceiveNativeKey event: NSEvent) -> Bool
    /// リンク以外のページ面でのクリック(左・中央・サイドボタン。
    /// 修飾キーの情報も含む)。
    /// 処理した場合は true、既定の動作を使う場合は false を返す。既定の動作は、
    /// 修飾キーなしの左クリックによる、左右の端タップでのページめくりだけ。
    ///
    /// A click on the page surface (non-link: left/middle/side buttons, with
    /// modifier keys). Return true if handled; false for the default action
    /// (only the left/right edge-tap page turn on an unmodified left click).
    func readerView(_ view: EPUBReaderView, didClick event: EPUBClickEvent) -> Bool
    /// 正規化済み本文の選択範囲が変わった。
    ///
    /// The normalized text selection changed.
    func readerView(_ view: EPUBReaderView,
                    selectionDidChange selection: EPUBTextSelection?)
    /// 方針に従って絞り込んだコンテキストメニューを、ホストが最後に
    /// カスタマイズする。コンテキストメニューのイベントごとに必ず 1 回呼ばれる。
    /// 絞り込み後のメニューが空の場合や、方針が
    /// ``EPUBContextMenuPolicy/suppressed`` の場合も同様。
    /// `nil` または空のメニューを返すと表示を抑止する。空でないメニューを
    /// 返せば、``EPUBContextMenuPolicy/suppressed`` でも表示する。
    ///
    /// Gives the host a final opportunity to customize a policy-filtered context
    /// menu. This method is called exactly once for every context-menu event,
    /// including when the filtered menu is empty and when the policy is
    /// ``EPUBContextMenuPolicy/suppressed``. Return `nil` or an empty menu to
    /// suppress presentation. A non-empty returned menu is presented even under
    /// ``EPUBContextMenuPolicy/suppressed``.
    func readerView(_ view: EPUBReaderView, willShowContextMenu menu: NSMenu,
                    at event: EPUBClickEvent?) -> NSMenu?
    /// ファイルのドロップ(ホストが「別の本を開く」などに使える)。
    /// ドロップを拒否する場合は false を返す。
    ///
    /// A file drop (which the host can use to "open another book", etc.).
    /// Return false to reject the drop.
    func readerView(_ view: EPUBReaderView,
                    didReceiveDroppedFileURL url: URL) -> Bool
    /// ピンチ操作などでフォント倍率が変わった(ホストでの保存に使う)。
    ///
    /// The font multiplier changed via pinch, etc. (for the host to persist).
    func readerView(_ view: EPUBReaderView, didChangeFontScale scale: Double)
    /// ページめくり効果を、ページカールなどホスト独自の効果に差し替える。
    /// oldPage/newPage は、ビューの座標系での pageRect に当たるページ領域の
    /// スナップショット。**このメソッド内で同期的に**ビューへオーバーレイを
    /// 追加し、true を返す(Washi はこのメソッドが戻るとすぐに古いページの
    /// カバーを外す)。
    /// 組み込みの pageTurnStyle(slide/fade)を使う場合は false を返す。
    ///
    /// Replace the page-turn effect with a host-specific one (page curl,
    /// etc.). oldPage/newPage are snapshots of the page area (pageRect, in the
    /// view's coordinate system). Add the overlay to the view **synchronously
    /// within this method** and return true (Washi removes the old page's
    /// cover as soon as this returns). Return false to use the built-in
    /// pageTurnStyle (slide/fade).
    func readerView(_ view: EPUBReaderView,
                    animatePageTurnFrom oldPage: NSImage, to newPage: NSImage,
                    forward: Bool, in pageRect: CGRect) -> Bool
    /// 読み込みの失敗などのエラー。
    ///
    /// A load failure or similar error.
    func readerView(_ view: EPUBReaderView, didFailWith error: any Error)
    /// 本全体のページ数の実測(census)が更新された(完了または無効化)。
    /// view.pageCensus / censusTotalPages / currentGlobalPageRange を参照。
    ///
    /// The whole-book page-count measurement (census) was updated (completed
    /// or invalidated). See view.pageCensus / censusTotalPages /
    /// currentGlobalPageRange.
    func readerViewDidUpdatePageCensus(_ view: EPUBReaderView)
    /// メディアオーバーレイ(SMIL)の再生が始まった、または一時停止・停止した。
    /// 再生/一時停止コントロールの状態を同期するために使う。
    ///
    /// Media-overlay (SMIL) playback started or paused/stopped. Use it to keep
    /// a play/pause control in sync.
    func readerView(_ view: EPUBReaderView,
                    isPlayingMediaOverlayDidChange isPlaying: Bool)
    /// メディアオーバーレイの再生が本の末尾に達した
    /// (これ以上再生するものがない)。
    ///
    /// Media-overlay playback reached the end of the book (nothing more to play).
    func readerViewMediaOverlayDidFinish(_ view: EPUBReaderView)
    /// 移動履歴が利用可能かどうかが変わった。
    /// ``EPUBReaderView/canGoBack`` を参照し、「戻る」コマンドやコントロールを
    /// 更新する。
    ///
    /// Navigation-history availability changed. Read ``EPUBReaderView/canGoBack``
    /// to update a Back command or control.
    func readerViewNavigationHistoryDidChange(_ view: EPUBReaderView)
    /// 解決済みの印刷ページのラベルが変わった。
    ///
    /// The resolved print page label changed.
    func readerView(_ view: EPUBReaderView,
                    didChangePrintPage label: String?)
}

public extension EPUBReaderViewDelegate {
    func readerView(_ view: EPUBReaderView, didMoveTo locator: EPUBLocator,
                    pageInItem: Int, pageCountInItem: Int) {}
    func readerView(_ view: EPUBReaderView, didReachBookEdge forward: Bool) {}
    func readerView(_ view: EPUBReaderView,
                    shouldOpenExternalURL url: URL) -> Bool { true }
    func readerView(_ view: EPUBReaderView,
                    shouldFollowInternalLink link: EPUBInternalLink) -> Bool { true }
    func readerView(_ view: EPUBReaderView, didReceiveKey event: EPUBKeyEvent) {}
    func readerView(_ view: EPUBReaderView,
                    shouldConsumeKey event: EPUBKeyEvent) -> Bool { true }
    func readerView(_ view: EPUBReaderView,
                    didReceiveNativeKey event: NSEvent) -> Bool { false }
    func readerView(_ view: EPUBReaderView,
                    didClick event: EPUBClickEvent) -> Bool { false }
    func readerView(_ view: EPUBReaderView,
                    selectionDidChange selection: EPUBTextSelection?) {}
    func readerView(_ view: EPUBReaderView, willShowContextMenu menu: NSMenu,
                    at event: EPUBClickEvent?) -> NSMenu? { menu }
    func readerView(_ view: EPUBReaderView,
                    didReceiveDroppedFileURL url: URL) -> Bool { false }
    func readerView(_ view: EPUBReaderView, didChangeFontScale scale: Double) {}
    func readerView(_ view: EPUBReaderView,
                    animatePageTurnFrom oldPage: NSImage, to newPage: NSImage,
                    forward: Bool, in pageRect: CGRect) -> Bool { false }
    func readerView(_ view: EPUBReaderView, didFailWith error: any Error) {}
    func readerViewDidUpdatePageCensus(_ view: EPUBReaderView) {}
    func readerView(_ view: EPUBReaderView,
                    isPlayingMediaOverlayDidChange isPlaying: Bool) {}
    func readerViewMediaOverlayDidFinish(_ view: EPUBReaderView) {}
    func readerViewNavigationHistoryDidChange(_ view: EPUBReaderView) {}
    func readerView(_ view: EPUBReaderView,
                    didChangePrintPage label: String?) {}
}
