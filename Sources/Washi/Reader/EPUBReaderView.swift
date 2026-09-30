import AppKit
import OSLog
import WebKit

// このファイルは EPUBReaderView の状態の一覧表: stored property は extension に
// 置けないため、すべての stored property と didSet、状態を持つ入れ子型、init と
// ライフサイクルをここに集め、各責務の処理は EPUBReaderView+*.swift の extension に置く。
// NSView や @objc メソッドの override が extension にあるのは、上位クラスのメソッドが
// Objective-C だからで、Swift だけのメンバーではできない(クラス本体へ戻さないこと)。

/// WKWebView ベースの EPUB リーダービュー。
/// リフローコンテンツは `ReaderScripts` のページ割りで描画し、
/// 固定レイアウトのコンテンツは pageZoom とフレーム調整により、
/// 縦横比を保って ICB 内に収める。
/// 余白はネイティブ側で実現する(webView のインセット配置とレイヤーの
/// 背景)。これにより CSS マルチカラムの座標計算を単純に保つ。
///
/// An EPUB reader view (WKWebView-based).
/// Reflowable content is drawn via `ReaderScripts` pagination; fixed-layout
/// content is aspect-fitted into its ICB (pageZoom + frame adjustment).
/// Margins are realized natively (inset placement of the webView + layer
/// background), which keeps the CSS multicol coordinate math simple.
@MainActor
public final class EPUBReaderView: NSView {
    static let logger = Logger(
        subsystem: "org.cocoadialog.Washi", category: "EPUBReaderView")

    public internal(set) var publication: EPUBPublication?
    public weak var delegate: (any EPUBReaderViewDelegate)?

    /// 現在の正規化済みテキスト選択。選択が空、または始点と終点が
    /// 同じ場合は `nil`。
    ///
    /// The current normalized text selection, or `nil` when the selection is
    /// empty or collapsed.
    public internal(set) var currentSelection: EPUBTextSelection?

    /// 本文に重ねて描画する、保存済みのハイライトとメモ。
    ///
    /// Saved highlights (and notes) to draw over the book.
    ///
    /// `spineIndex` または `idref` が表示中の項目と一致するものだけを
    /// 描画する。残りも保持するため、ページをめくった際に追加の
    /// やり取りなしで表示できる。描画には CSS Custom Highlight API を使い、
    /// 本の DOM を変更せず、範囲が重なっても要素を入れ子にしない。
    /// 錨は抽出本文の UTF-16 範囲なので、文字サイズ・ビューポート・
    /// テーマを変えてもずれない(cooViewer-oxr.46 C40)。
    ///
    /// Only the ones whose `spineIndex` (or `idref`) matches the item on screen
    /// are drawn; the rest are kept so a page turn shows them without another
    /// round trip. Drawing uses the CSS Custom Highlight API, so the book's DOM
    /// is never modified and overlapping ranges do not nest elements.
    /// Anchors are extracted-text UTF-16 ranges, so they survive font-size,
    /// viewport and theme changes (cooViewer-oxr.46 C40).
    public var highlights: [EPUBHighlight] = [] {
        didSet {
            guard highlights != oldValue else { return }
            applyHighlights()
            // 現在の項目に描くハイライトが変わったときだけ撮り直す。撮り直すまでは前の控えを残す
            // (控えなしで地色が見えるより害が小さい。検索の例のように別の章のハイライトを
            // 設定してすぐ移動しても控えを使える)。
            if highlightsOnCurrentItem(oldValue) != highlightsOnCurrentItem(highlights) {
                schedulePageCoverPrefetchAfterFrames()
            }
        }
    }

    /// 出版物のページリストで宣言された印刷ページのラベル(文書順)。
    ///
    /// Print page labels declared by the publication's page list, in document
    /// order.
    public var printPageLabels: [String] {
        flattenedPrintPageList.map(\.title)
    }

    /// 確定した読書位置、またはそれ以前にある最後の印刷ページマーカー。
    ///
    /// The last print page marker at or before the settled reading position.
    public internal(set) var currentPrintPage: String?

    public var settings = EPUBReaderSettings() {
        didSet {
            guard oldValue != settings else { return }
            let layoutChanged = layoutKey(for: oldValue) != layoutKey(for: settings)
            applyTheme()
            updateAccessibilityMetadata()
            if oldValue.announcesPageChanges && !settings.announcesPageChanges {
                accessibilityAnnouncementTask?.cancel()
                accessibilityAnnouncementTask = nil
            }
            if oldValue.forwardsKeyEventsNatively
                != settings.forwardsKeyEventsNatively {
                updateNativeKeyMonitor()
            }
            if oldValue.handlesKeyboardNavigation
                != settings.handlesKeyboardNavigation {
                // cooViewer-oxr.24: setup 後の切替も現在の文書へ即時反映する。
                evaluate("__washi.setKeysEnabled(\(settings.handlesKeyboardNavigation));")
            }
            if oldValue.defersTapsForDoubleClick
                != settings.defersTapsForDoubleClick {
                // cooViewer-oxr.27: ページ割りを伴わない入力設定も現在文書へ即時反映する。
                updateTapDeferral()
            }
            if oldValue.allowsScriptedContent != settings.allowsScriptedContent {
                // JS 許可はビュー構成ごと作り直す(WKWebViewConfiguration は不変)
                reloadCurrentPublication()
            } else if layoutChanged {
                // cooViewer-oxr.24: 個別フィールド列挙ではなく census と同じ
                // 導出キーを正とし、userCSS を含む変更漏れを防ぐ。
                needsLayout = true
                // 組版(同じ代入で変えた配色を含む)が変わるので今の控えは使えない。
                // 撮り直しは runSetup の最後。
                dropPrefetchedPageCover()
                schedulePagination(preserveProgression: true)
            } else {
                // 配色・めくり演出・柱の表示などはページ割りを保ったまま反映
                let appearanceChanged = oldValue.composedUserCSS(
                    isDark: isDark(for: oldValue.theme),
                    increaseContrast: shouldIncreaseContrast,
                    differentiateWithoutColor: shouldDifferentiateWithoutColor)
                    != settings.composedUserCSS(
                        isDark: isDark(for: settings.theme),
                        increaseContrast: shouldIncreaseContrast,
                        differentiateWithoutColor: shouldDifferentiateWithoutColor)
                // 配色の CSS が変わらない設定(キー操作・読み上げの通知・柱の表示など)では控えを捨てない。
                applyThemeCSSOnly(retakesCover: appearanceChanged)
                updateFurniture()
            }
        }
    }

    var webView: WKWebView?
    var schemeHandler: EPUBSchemeHandler?
    var messageProxy: MessageProxy?

    struct PrintPageMarker: Equatable {
        let label: String
        let page: Int
    }
    var printPageMarkers: [PrintPageMarker] = []

    /// cooViewer-oxr.37: テストは VoiceOver プロセスへ依存せず、確定した
    /// アナウンス文字列をこの seam で捕捉する。
    var accessibilityAnnouncementHandler: ((String) -> Void)?
    var accessibilityAnnouncementDelay: Duration = .milliseconds(150)
    var accessibilityPreferredLanguageOverride: String?
    var accessibilityIncreaseContrastOverride: Bool? {
        didSet { accessibilityDisplayOptionsDidChange() }
    }
    var accessibilityDifferentiateWithoutColorOverride: Bool? {
        didSet { accessibilityDisplayOptionsDidChange() }
    }
    // OS の設定を変更せず、演出の有無と取り消しを両方検証する。
    // 未指定なら常に現在のアクセシビリティ設定に従う。
    var accessibilityReduceMotionOverride: Bool?
    var accessibilityShouldReduceMotion: Bool {
        accessibilityReduceMotionOverride
            ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
    var accessibilityAnnouncementTask: Task<Void, Never>?
    struct SettledPageIdentity: Equatable {
        let spineIndex: Int
        let page: Int
        let pageCount: Int
    }
    var lastAnnouncedPage: SettledPageIdentity?

    /// ノンブル(各ページの下部中央に素のページ番号。Apple Books 風)。
    /// 見開き時は左右 1 つずつ、単ページ時は先頭だけ使う
    let pageNumberLabels = [NSTextField(labelWithString: ""),
                                    NSTextField(labelWithString: "")]
    /// 現在ページが「画像 1 枚だけのページ」(表紙等)か。ノンブルを隠す
    var isImagePage = false
    /// 画像 1 枚だけの項目(表紙・挿絵)か。項目の読み込み時に publication から判定するので、
    /// JS のページ割り結果を待つ ``isImagePage`` と違い、最初のページ割りの前に決まる。
    var isImageOnlyItem = false
    /// 実行時の 1 画面あたりのページ数(1 = 単ページ / 2 = 見開き)。
    /// 画像 1 枚だけのページでは見開きモードでも 1 になる。見開きの
    /// 切り替えには ``plannedPagesPerScreen`` または
    /// ``toggleColumnMode()`` を使う。
    ///
    /// Run-time number of pages per screen (1 = single page / 2 = spread).
    /// Single-image pages report 1 even in spread mode; use
    /// ``plannedPagesPerScreen`` or ``toggleColumnMode()`` for a spread toggle.
    public internal(set) var pagesPerScreen = 1

    /// この WebKit が縦組みの見開きに必要な column-axis 機能を
    /// サポートするかどうか。未対応のエンジンでは単ページに切り替わる。
    ///
    /// Whether this WebKit supports the column-axis feature required for
    /// vertical two-page spreads. Unsupported engines fall back to one page.
    public internal(set) var columnAxisSupported = true
    /// JS が実測した先頭読書スロット。OPF の綴じ方向と本文 CSS が食い違う本でも、
    /// 可視ページとネイティブのノンブルを同じ側へ置く(cooViewer-oxr.58)。
    var firstPageOnRight = false

    // MARK: - 読み込み状態

    /// 現在の読書位置。
    ///
    /// Current position
    public internal(set) var currentSpineIndex = 0
    public internal(set) var pageInItem = 0
    public internal(set) var pageCountInItem = 1
    var isFixedLayoutItem = false
    var scrollProgression: Double?
    var loadedScrollGroup: Range<Int>?
    var effectiveFlow: RenditionFlow {
        publication?.renderingFlow(at: currentSpineIndex) ?? .auto
    }

    /// 過去に記録した移動位置へ戻れるかどうか。
    ///
    /// Whether a previously recorded navigation position is available.
    public internal(set) var canGoBack = false
    /// cooViewer-oxr.31: ページめくりとは分離したジャンプ履歴を有限に保つ。
    var navigationHistory: [EPUBLocator] = []
    static let navigationHistoryLimit = 50

    /// 読み込み完了時に適用する表示位置
    enum PendingTarget {
        case start
        case end
        case progression(Double)
        case fragment(String)
        case textRange(utf16Offset: Int, utf16Length: Int, fallbackProgression: Double)
    }
    var pendingTarget: PendingTarget = .start
    struct PendingTextRangeRequest {
        let id: UUID
        let continuation: CheckedContinuation<EPUBTextRangeLanding?, Never>
    }
    var pendingTextRangeRequest: PendingTextRangeRequest?
    var textRangeTask: Task<Void, Never>?
    // JS との境界だけを差し替え、実 WebKit なしでアンカー移動と取消を検証する。
    var textRangeLocationHandler: ((Int, Int) async -> EPUBTextRangeLanding?)?
    var scriptEvaluationHandler: ((String) -> Void)?
    var isSettingUp = false
    /// spine 項目の読み込み中(旧文書から届く境界イベントを捨てて
    /// 章の飛び越しを防ぐ)
    var isLoadingSpineItem = false
    /// setup 済みの文書を離れる最初の移動元。読み込みの置き換え中も保持する。
    var settledLocator: EPUBLocator?
    var isShowingSetUpDocument = false
    var isRecoveryLoad = false
    // WebKit が読み込みを開始しない場合を、実際の再読み込みと組み合わせて検証する。
    var spineLoadHandler: ((URLRequest) -> WKNavigation?)?
    /// spine 読み込みの世代。loadSpineItem のたびに進める。
    /// runSetup は「開始時と各 await 後」に世代一致を確認し、高速なページ
    /// 送りで古いセットアップが新しい文書の状態(pendingTarget・
    /// isLoadingSpineItem・復元位置)を消費・破壊しないようにする
    var spineLoadGeneration = 0
    /// cooViewer-oxr.46 C35: setup ごとに更新する文書の印。JS からの通知に
    /// 同じ値が付いていなければ、差し替え前の文書からの遅配とみなして捨てる。
    /// (isLoadingSpineItem のガードは「読み込み中」しか見ないため、新文書が
    /// 確定した後に届く旧文書の report を弾けない)
    var currentDocumentToken: String { "g\(spineLoadGeneration)" }
    /// 印を持たない通知(古い注入・ラスタライザ経路)は従来どおり受け入れる
    func isFromCurrentDocument(_ dict: [String: Any]) -> Bool {
        guard let token = dict["token"] as? String else { return true }
        return token == currentDocumentToken
    }
    // delegate 通知中の load/go は新しい要求。外側の旧要求を続行させない。
    var navigationRequestGeneration: UInt = 0

    func beginNavigationRequest() -> UInt {
        navigationRequestGeneration &+= 1
        return navigationRequestGeneration
    }
    /// 現在有効なナビゲーション(didFinish/didFail の遅延配達を、後続の
    /// loadSpineItem 後に古い文書ぶんとして無視するための同一性チェック)
    var currentNavigation: WKNavigation?
    /// loadSpineItem 自身の .other と文書内遷移の .other を区別する
    var spineNavigationGate = SpineNavigationGate()

    // MARK: - 入力

    /// ネイティブキー横取りのローカルモニタ(forwardsKeyEventsNatively)
    var keyEventMonitor: Any?
    var isRoutingKeyDown = false
    // WebKit は未処理キーを同じ NSEvent で NSApp へ再送する。
    // 弱い同一性キーで配達結果を保持し、再送・同期再入でも delegate は一度にする。
    let nativeKeyResults = NSMapTable<NSEvent, NSNumber>(
        keyOptions: [.weakMemory, .objectPointerPersonality], valueOptions: .strongMemory)

    /// ピンチ開始時の倍率(確定は指を離したとき)
    var pinchBaseFontScale: Double?

    var marginPressTime: TimeInterval = 0
    var marginPressLocation = NSPoint.zero

    var marginWheelAccumulator: CGFloat = 0
    var marginWheelLastTime: TimeInterval = 0
    var marginWheelLatched = false
    var marginWheelHorizontal = false

    // MARK: - メディアオーバーレイ

    /// メディアオーバーレイ(SMIL)再生エンジン(再生時に生成)
    var mediaOverlayController: MediaOverlayController?
    /// 読み込み中の読み上げハイライトは旧文書へ送らず、新文書の setup 後に適用する。
    /// 解除(fragmentID が nil)も保持し、読み込み中は最後の要求だけを使う。
    var pendingMediaOverlayHighlight: (fragmentID: String?, cssClass: String)?
    /// `playMediaOverlayFromCurrentPage()` の JS 応答より後に届いた操作が、
    /// 古い応答から再生を開始しないためのコマンド世代。
    var mediaOverlayCommandGeneration: UInt = 0
    struct MediaOverlayDocumentContext: Equatable {
        let publication: ObjectIdentifier?
        let navigationRequest: UInt
        let spineLoad: Int
        let spineIndex: Int
        let pageInItem: Int
    }

    // MARK: - カバーと転換

    /// めくりアニメーションのオーバーレイ(spine 切替時に掃除)
    var turnOverlays: [NSView] = []
    // 直近に予約した演出処理。テストは固定時間の sleep でなく、この終了を待つ。
    var lastAnimatedTurnTask: Task<Void, Never>?
    /// 直前のめくり時刻(高速連打時はアニメーションを省略して即めくり)
    var lastTurnDate = Date.distantPast

    /// 控えは常に 1 枚だけ持つ(等倍なので全画面では数十 MB になる)
    var prefetchedPageCover: PrefetchedPageCover?
    var pageCoverPrefetchTask: Task<Void, Never>?
    var pageCoverPrefetchRetries = 0
    /// spine を離れる直前に、離れるページのものと確認できた控え。didCommit で貼る
    var armedSpineCover: PrefetchedPageCover?
    /// 読み込み前に決め、didCommit で当てる WebView の矩形と倍率
    var pendingWebViewLayout: (frame: NSRect, zoom: CGFloat, generation: Int)?
    /// spine の読み込みを始めてからコミットまでの間か(置き換えた前の読み込みの
    /// コミットでも終わる)。前の文書が見えているのでノンブルを隠す
    /// (新しい項目の番号を前のページの上に出さない)
    /// この間に次の読み込みが始まったら、取り置いた控えを引き継ぐ(Washi-3b1)
    var isAwaitingCommit = false

    var pendingSpineTurn: PendingSpineTurn?

    /// カバー同一性 → 時間切れ回収タスク。所有権を失った(上書きされた)カバーも
    /// membership で回収するため、pendingSpineTurn ではなくカバーごとに持つ。
    /// 演出中(runTurnEffect)や仕上げ時は明示 cancel してスライド途中で
    /// カバーを引き剥がさない
    var spineTurnTimeouts: [ObjectIdentifier: Task<Void, Never>] = [:]

    /// めくりカバー掲示中はライブのノンブルを隠す。番号はカバー(全面合成)に
    /// 焼き込み済みで、カバーはラベルより背面に入るため、隠さないと演出中に
    /// ライブ側の新番号と焼き込みの旧番号が二重に見える。章読み込み中に
    /// ラベルが一瞬「1」へ戻って見えていた従来のチラつきも同時に消える
    var furnitureSuppressed = false {
        didSet { if furnitureSuppressed != oldValue { updateFurniture() } }
    }

    // MARK: - レイアウトと再ページ割り

    /// セットアップ実行中に届いた再ページ割り要求(捨てずに後追い実行する)
    var pendingRepaginate = false
    var repaginateWork: Task<Void, Never>?
    var lastLaidOutSize: CGSize = .zero
    /// cooViewer-oxr.54: 不可視中に畳んだレイアウトを、再表示時に一度だけ行う。
    var pendingVisibleLayout = false
    /// 復元先(復元完了まで currentLocator の答えとして使う。復元前の保存で
    /// 位置が (0,0) に潰れるのを防ぐ)
    var pendingRestoreLocator: EPUBLocator?
    /// FXL の viewport キャッシュ(layoutFixedItem がリサイズ毎に XHTML を
    /// 再パースしないため)
    var fxlViewportCache: [Int: CGSize] = [:]
    /// cooViewer-oxr.50: device-* viewport は寸法でなく種別だけをキャッシュし、
    /// 実寸は毎回現在の表示領域から取る。
    var fxlDeviceSizedViewportItems: Set<Int> = []

    // MARK: - census

    /// 現在のメトリクスでの各 spine 項目のページ数(実測完了までは nil)。
    /// 文字サイズ、ウインドウ寸法、見開きモードが変わるたびに再実測する。
    ///
    /// Page count of each spine item at the current metrics (nil until the
    /// measurement completes). Re-measured whenever the font size, window
    /// dimensions, or spread mode change.
    public internal(set) var pageCensus: [Int]?

    var censusEngine: EPUBPaginationCensus?
    var censusTask: Task<Void, Never>?
    /// 計測時のメトリクスキー(census 用オプション JSON。sortedKeys で決定的)
    var censusKey: String?
    /// メトリクスキー → 実測結果(フォントを行き来したときの再計測を省く)
    var censusCache: [String: [Int]] = [:]

    var thumbnailRenderer: EPUBScreenThumbnailRenderer?

    /// メトリクスごとの実測失敗台帳(2-strike + TTL)。上限を超えたキーは
    /// 再スケジュールしない(壊れた spine を持つ本で runSetup のたびに 15 秒
    /// タイムアウトを繰り返さないため)が、TTL 経過で赦して再挑戦させる
    /// (一時要因で欠けたページ数がセッション中ずっと出ないのを防ぐ)
    var censusFailures = CensusFailureLedger()

    // MARK: - WebContent 再読込

    /// WebContent 終了の再読み込みは同一 spine の短時間ループを有限にする。
    var webContentReloadLimiter = WebContentReloadLimiter()
    var pendingWebContentReloadDelay: Duration?
    var webContentReloadTask: Task<Void, Never>?
    var webContentReloadRequestCount = 0
    var webContentReloadAttemptCount = 0
    var hasPendingWebContentReload: Bool {
        webContentReloadTask != nil || pendingWebContentReloadDelay != nil
    }

    // MARK: - テスト用の差し替え点

    /// 描画フレームを 2 回待つ処理。テストで差し替えられる
    var animationFrameWait: @MainActor (WKWebView) async -> Void = { webView in
        await EPUBReaderView.waitForWashiScript(
            "await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r))); return true;",
            in: webView)
    }

    /// 描画フレームの待ちを打ち切るまでの時間。テストで差し替えられる
    var animationFrameWaitTimeout = Duration.milliseconds(600)

    /// テスト用: ウインドウが画面に出ているかを OS の遮蔽判定に依らず決める。
    /// 画面外に置いたテストウインドウは遮蔽扱いで、控えを撮らないため
    var isWindowOnScreenOverride: Bool?

    /// 外部ネットワークを遮断するコンテンツルール(コンパイルは初回のみ)
    static let contentRuleList: Task<WKContentRuleList?, Never> = Task { @MainActor in
        let json = """
        [
          {"trigger": {"url-filter": "https?://.*"}, "action": {"type": "block"}},
          {"trigger": {"url-filter": "wss?://.*"}, "action": {"type": "block"}},
          {"trigger": {"url-filter": "^washi-epub://.*"},
           "action": {"type": "ignore-previous-rules"}}
        ]
        """
        return try? await WKContentRuleListStore.default()?
            .compileContentRuleList(forIdentifier: "washi-network-lockdown",
                                    encodedContentRuleList: json)
    }

    // MARK: - ライフサイクル

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        for label in pageNumberLabels {
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            label.alignment = .center
            label.lineBreakMode = .byTruncatingTail
            label.isHidden = true
            // cooViewer-oxr.37: ノンブルは独立要素にせず reader の value とする。
            label.setAccessibilityElement(false)
            addSubview(label)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        updateAccessibilityMetadata()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityDisplayOptionsDidChange),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil)
        // ファイルドロップはホスト(delegate)に委ねる(「別の本を開く」等)
        registerForDraggedTypes([.fileURL])
        // ピンチ=フォント倍率(リフローの自然な拡大。認識器なら WKWebView 上の
        // ジェスチャも確実に届く)
        addGestureRecognizer(NSMagnificationGestureRecognizer(
            target: self, action: #selector(handleMagnification(_:))))
        applyTheme()
    }
}
