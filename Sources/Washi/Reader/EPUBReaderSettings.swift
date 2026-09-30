import AppKit

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
    /// 固定レイアウト(FXL)のページと、ページ単位の表示でのリフローの
    /// 画像 1 枚だけの項目(表紙・挿絵)には適用せず、余白なしで全面に表示する。
    ///
    /// Content insets. The WKWebView itself is inset, keeping the multicol
    /// coordinate system simple. The margins are painted as the native
    /// background, and each page's folio (page number) sits in the bottom
    /// margin — mirroring Apple Books' page-layout design. Not applied to
    /// fixed-layout (FXL) pages or, in paginated display, to reflowable
    /// single-image items such as covers and illustrations (which display
    /// full-bleed).
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
