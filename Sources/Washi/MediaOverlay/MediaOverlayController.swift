import AVFoundation
import Foundation

protocol MediaOverlayAudioPlayer: AnyObject {
    var currentTime: TimeInterval { get set }
    var duration: TimeInterval { get }
    var isPlaying: Bool { get }
    var enableRate: Bool { get set }
    var rate: Float { get set }
    @discardableResult func prepareToPlay() -> Bool
    @discardableResult func play() -> Bool
    func pause()
    func stop()
}

extension AVAudioPlayer: MediaOverlayAudioPlayer {}

/// メディアオーバーレイ(SMIL)の音声同期再生エンジン。
/// par(text 断片 + audio クリップ)を順に再生し、テキストへ active-class を
/// 付けてページを追従させる。項目末尾では次のオーバーレイへ連続再生する
/// (オーディオブック用途)。EPUBReaderView が所有し、そこから駆動する
@MainActor
final class MediaOverlayController {
    private weak var reader: EPUBReaderView?
    private let publication: EPUBPublication
    private let makeAudioPlayer: (Data) throws -> any MediaOverlayAudioPlayer
    /// 再生中テキストへ付ける CSS クラス(media:active-class か既定)
    private let activeClass: String

    private var overlay: MediaOverlay?
    /// 再生中の spine 項目(ホストが現在項目と突き合わせて古い章の再開を防ぐ。
    /// テストの観測点でもある)
    private(set) var spineIndex = 0
    /// 再生中の par 番号(テストの観測点)
    private(set) var parIndex = 0
    private var player: (any MediaOverlayAudioPlayer)?
    private var loadedAudioPath: String?
    private var ticker: Timer?
    private(set) var isPlaying = false
    private var playbackGeneration: UInt = 0
    /// 項目末尾で次項目のオーバーレイへ連続再生するか(既定 true)
    var continuesToNextItem = true
    /// 再生速度(1.0 = 収録速度)。0.5〜3.0 へ丸める
    var playbackRate: Double = 1.0 {
        didSet { applyPlaybackRate() }
    }
    /// cooViewer-oxr.46 C26 / RS 3.3 §9.4.1: 読み飛ばす epub:type。
    var skippedTypes: Set<String> = []
    /// 再生位置(ホストが保存して次回復元するため)。停止・完了後は位置を持たない。
    var position: (spineIndex: Int, parIndex: Int)? {
        overlay == nil ? nil : (spineIndex, parIndex)
    }

    init(reader: EPUBReaderView, publication: EPUBPublication,
         activeClass: String,
         makeAudioPlayer: @escaping (Data) throws -> any MediaOverlayAudioPlayer = {
             try AVAudioPlayer(data: $0)
         }) {
        self.reader = reader
        self.publication = publication
        self.activeClass = activeClass
        self.makeAudioPlayer = makeAudioPlayer
    }

    /// 指定 spine 項目のオーバーレイを先頭から再生する(既に再生中なら停止して開始)
    func play(fromSpineIndex index: Int, parIndex startPar: Int? = nil) {
        playbackGeneration &+= 1
        stopAudio()
        spineIndex = index
        overlay = publication.mediaOverlay(forSpineIndex: index)
        guard let overlay, !overlay.parallels.isEmpty else {
            finish()
            return
        }
        if let startPar {
            parIndex = max(0, startPar)
        } else {
            // 1 つの SMIL が複数の spine 文書を記述することがある。後ろの文書から
            // 再生を始めるときはその文書の最初の par から入り、前の文書の
            // par 0 へ巻き戻さない。
            if let first = overlay.parallels.firstIndex(where: {
                spineIndex(forPar: $0, in: overlay) == index
            }) {
                parIndex = first
            } else if overlayWasIntroducedBefore(spineIndex: index) {
                // 不正な共有 SMIL はこの文書をまったく含まないことがある。
                // 前の文書へ戻ってリーダーを後ろへ引き戻さない。この項目には
                // 有効なナレーションの入口がない。
                finish()
                return
            } else {
                parIndex = 0
            }
        }
        if parIndex >= overlay.parallels.count { parIndex = 0 }
        let generation = playbackGeneration
        if startCurrentPar(seek: true), generation == playbackGeneration {
            setPlaying(true)
        }
    }

    /// 一時停止(ハイライトは残す)
    func pause() {
        playbackGeneration &+= 1
        player?.pause()
        ticker?.invalidate(); ticker = nil
        setPlaying(false)
    }

    /// 一時停止からの再開
    func resume() {
        playbackGeneration &+= 1
        guard let overlay, overlay.parallels.indices.contains(parIndex) else {
            play(fromSpineIndex: spineIndex)
            return
        }
        // 無音・音声なしの par にも再開できる位置がある。章全体をやり直さず、
        // その par の送りタイマーを作り直す。
        let generation = playbackGeneration
        if startCurrentPar(seek: false), generation == playbackGeneration {
            setPlaying(true)
        }
    }

    /// 停止してハイライトを消す
    func stop() {
        playbackGeneration &+= 1
        stopAudio()
        clearHighlight()
        overlay = nil
        setPlaying(false)
    }

    // MARK: - 内部

    private func stopAudio() {
        ticker?.invalidate(); ticker = nil
        player?.stop()
        player = nil
        loadedAudioPath = nil
    }

    /// 現在の par を鳴らす(必要なら音声を読み込み・シーク)+ ハイライト。
    /// 音声が無い/読み込めない par(テキストのみ・DRM・欠落・非対応形式)は
    /// 空回りせず短い間だけハイライトして次へ進める(無限ストール防止)
    @discardableResult
    private func startCurrentPar(seek: Bool, continuingAudio: String? = nil,
                                 startingAt startParIndex: Int? = nil) -> Bool {
        let generation = playbackGeneration
        let initialSpineIndex = spineIndex
        var candidateSpineIndex = spineIndex
        var candidateParIndex = startParIndex ?? parIndex
        var candidateOverlay = overlay
        var shouldSeek = seek
        var mayContinueAudio = continuingAudio != nil
        var changedItem = false
        // 平坦な SMIL には読み飛ばす par が数万個あることがある。advancePar /
        // startCurrentPar を(spine 項目をまたいでも)再帰させない。
        while true {
            if let candidateOverlay,
               candidateParIndex < candidateOverlay.parallels.count {
                if Self.isSkipped(candidateOverlay.parallels[candidateParIndex],
                                  types: skippedTypes) {
                    candidateParIndex += 1
                    shouldSeek = true
                    mayContinueAudio = false
                    continue
                }
                break
            }
            if !changedItem {
                // ユーザーがナレーション中の章を離れていたら止める。この判定は
                // この操作での自動移動より前に行う。
                if let displayed = reader?.currentSpineIndex, displayed != initialSpineIndex {
                    finish()
                    return false
                }
            }
            guard continuesToNextItem,
                  let nextIndex = nextSpineIndexWithOverlay(after: candidateSpineIndex)
            else { finish(); return false }
            candidateSpineIndex = nextIndex
            candidateParIndex = 0
            candidateOverlay = publication.mediaOverlay(forSpineIndex: nextIndex)
            changedItem = true
            shouldSeek = true
            mayContinueAudio = false
        }
        guard let candidateOverlay,
              candidateOverlay.parallels.indices.contains(candidateParIndex) else {
            finish()
            return false
        }
        if changedItem {
            // 読み飛ばした章ごとではなく、再生できる par が見つかってから移動する。
            // delegate が再生を停止・再開したり本を差し替えたりすることがある。
            stopAudio()
            reader?.navigateForMediaOverlay(toSpineIndex: candidateSpineIndex)
            guard generation == playbackGeneration,
                  reader?.mediaOverlayController === self,
                  reader?.currentSpineIndex == candidateSpineIndex else {
                finishTransitionIfStillCurrent(generation: generation)
                return false
            }
        }
        spineIndex = candidateSpineIndex
        parIndex = candidateParIndex
        overlay = candidateOverlay
        let overlay = candidateOverlay
        let par = overlay.parallels[parIndex]
        // 音声を始める前に、移動とホストのコールバックを落ち着かせる。コール
        // バックがこの遷移を上書きしても、取り残された player を鳴らし続けない。
        guard highlight(par: par), generation == playbackGeneration else {
            finishTransitionIfStillCurrent(generation: generation)
            return false
        }
        if mayContinueAudio, par.audioHref == continuingAudio, let player,
           player.isPlaying, abs(player.currentTime - par.clipBegin) < 0.25 {
            return true
        }
        if let audioHref = par.audioHref,
           let audioPath = ContainerPath.resolve(base: overlay.basePath,
                                                 href: audioHref) {
            if audioPath != loadedAudioPath {
                loadAudio(path: audioPath)
            }
            if let player {
                if shouldSeek { player.currentTime = par.clipBegin }
                // cooViewer-oxr.46 C08: play() の失敗を無視すると、tick が
                // !isPlaying を見て即座に次の par へ進み、25ms 間隔で本の
                // 終わりまで駆け抜ける。失敗したら音声の無い par と同じ扱いにする。
                applyPlaybackRate()
                if player.play() {
                    startTicker()
                    return true
                }
            }
        }
        // 音声を用意できない par: ハイライトだけして一定時間後に次へ
        stopAudio()
        scheduleSilentAdvance()
        return true
    }

    /// 音声の無い/失敗した par を、決まった短い間ののち次へ送る一発タイマー
    private func scheduleSilentAdvance() {
        scheduleTicker(interval: 0.4, repeats: false) { controller in
            guard controller.isPlaying else { return }
            controller.advancePar()
        }
    }

    /// cooViewer-oxr.46 C08: Timer.scheduledTimer は .default モードにしか
    /// 入らないため、ライブリサイズやメニュー追跡の間 tick が止まる。その間に
    /// 音声だけ進むと clipEnd を跨いでしまい、復帰後の連続判定が外れて
    /// clipBegin へ巻き戻る。.common モードへ入れて止まらないようにする。
    private func scheduleTicker(
        interval: TimeInterval, repeats: Bool,
        _ body: @escaping @Sendable @MainActor (MediaOverlayController) -> Void
    ) {
        ticker?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: repeats) { [weak self] timer in
            // 繰り返しタイマーは実行ループが保持するので、所有者が消えても
            // invalidate するまで 25ms ごとに起き続ける。空振りに気づいた
            // 時点で自分を止める(所有者側の stop() が最初の防衛線)。
            guard let self else {
                timer.invalidate()
                return
            }
            MainActor.assumeIsolated { body(self) }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    /// epub:type は空白区切りの複数値。1 つでも該当すれば読み飛ばす。
    static func isSkipped(_ par: MediaOverlay.Parallel,
                          types: Set<String>) -> Bool {
        guard !types.isEmpty, let epubType = par.epubType else { return false }
        for value in epubType.split(whereSeparator: { $0.isWhitespace }) {
            // "frontmatter:pagebreak" のような接頭辞付きも末尾で判定する
            let bare = value.split(separator: ":").last.map(String.init) ?? String(value)
            if types.contains(bare) || types.contains(String(value)) { return true }
        }
        return false
    }

    private func applyPlaybackRate() {
        guard let player else { return }
        let requested = playbackRate.isFinite ? playbackRate : 1
        let clamped = min(max(requested, 0.5), 3.0)
        player.enableRate = true
        player.rate = Float(clamped)
    }

    private func loadAudio(path: String) {
        guard let (data, _) = try? publication.resource(at: path),
              let newPlayer = try? makeAudioPlayer(data) else {
            player = nil
            loadedAudioPath = nil
            return
        }
        newPlayer.prepareToPlay()
        player = newPlayer
        loadedAudioPath = path
    }

    private func startTicker() {
        // 25ms 間隔で clipEnd 到達を監視して par を進める
        scheduleTicker(interval: 0.025, repeats: true) { $0.tick() }
    }

    private func tick() {
        guard isPlaying, let overlay, let player,
              overlay.parallels.indices.contains(parIndex) else { return }
        let par = overlay.parallels[parIndex]
        let end = par.clipEnd ?? player.duration
        // クリップ終端(または音声終端)に達したら次の par へ
        if player.currentTime >= end - 0.005 || !player.isPlaying {
            advancePar()
        }
    }

    private func advancePar() {
        guard let overlay, overlay.parallels.indices.contains(parIndex) else { return }
        // このクリップの再生中にユーザーが別の場所へ移動していたら、古い章の
        // ナレーションを続けず、次のハイライトで表示を引き戻さない。
        if let displayed = reader?.currentSpineIndex, displayed != spineIndex {
            finish()
            return
        }
        let previousAudio = overlay.parallels[parIndex].audioHref
        // 同じ音声ファイル内の連続クリップも含め、すべての遷移が読み飛ばし
        // フィルタを通る。読み飛ばされない隣接クリップだけが再生を続ける。
        startCurrentPar(seek: true, continuingAudio: previousAudio,
                        startingAt: parIndex + 1)
    }

    private func finishTransitionIfStillCurrent(generation: UInt) {
        guard generation == playbackGeneration,
              reader?.mediaOverlayController === self else { return }
        finish()
    }

    private func finish() {
        let generation = playbackGeneration
        stopAudio()
        clearHighlight()
        overlay = nil
        setPlaying(false)
        // 状態コールバックは別の本の読み込み・再生の再開・停止を行いうる。
        // 古い完了通知をその新しい操作へ届けない。
        guard generation == playbackGeneration,
              reader?.mediaOverlayController === self else { return }
        reader?.mediaOverlayDidFinish()
    }

    /// 次に再生すべき spine 項目。cooViewer-oxr.46 C07: 1 つの SMIL が
    /// 複数の XHTML を束ねる本では隣の項目も同じ SMIL を指すため、同じ
    /// SMIL の項目は飛ばす(飛ばさないと同じ音声を par 0 から鳴らし直す)。
    private func nextSpineIndexWithOverlay(after index: Int) -> Int? {
        let order = publication.readingOrder
        let currentOverlayPath = publication.mediaOverlayPath(forSpineIndex: index)
        var i = index + 1
        while i < order.count {
            if order[i].item.mediaOverlay != nil,
               publication.mediaOverlayPath(forSpineIndex: i) != currentOverlayPath {
                return i
            }
            i += 1
        }
        return nil
    }

    private func overlayWasIntroducedBefore(spineIndex index: Int) -> Bool {
        guard index > 0,
              let path = publication.mediaOverlayPath(forSpineIndex: index) else {
            return false
        }
        return publication.readingOrder[..<index].indices.contains {
            publication.mediaOverlayPath(forSpineIndex: $0) == path
        }
    }

    private func highlight(par: MediaOverlay.Parallel) -> Bool {
        // cooViewer-oxr.46 C07: 1 つの SMIL が複数の XHTML を束ねる本では、
        // par の textHref が別の文書を指すことがある。文書部分を捨てると
        // その par のハイライトが空振りするので、必要なら先に移動する。
        if let target = spineIndex(forPar: par), target != spineIndex {
            let generation = playbackGeneration
            reader?.navigateForMediaOverlay(toSpineIndex: target)
            guard generation == playbackGeneration,
                  reader?.mediaOverlayController === self,
                  reader?.currentSpineIndex == target else { return false }
            spineIndex = target
        }
        reader?.mediaOverlayHighlight(
            fragmentID: par.textHref.flatMap(ContainerPath.fragment(of:)),
            cssClass: activeClass)
        return true
    }

    /// par の text が指す spine 項目(同じ文書内なら nil ではなく現在値を返す)
    private func spineIndex(forPar par: MediaOverlay.Parallel) -> Int? {
        guard let overlay else { return nil }
        return spineIndex(forPar: par, in: overlay)
    }

    private func spineIndex(forPar par: MediaOverlay.Parallel,
                            in overlay: MediaOverlay) -> Int? {
        guard let href = par.textHref else { return nil }
        let withoutFragment = ContainerPath.documentPart(of: href)
        guard !withoutFragment.isEmpty,
              let path = ContainerPath.resolve(base: overlay.basePath,
                                               href: withoutFragment)
        else { return nil }
        return publication.spineIndex(forContainerPath: path)
    }

    private func clearHighlight() {
        reader?.mediaOverlayHighlight(fragmentID: nil, cssClass: activeClass)
    }

    private func setPlaying(_ playing: Bool) {
        guard isPlaying != playing else { return }
        isPlaying = playing
        reader?.mediaOverlayPlayingChanged(playing)
    }
}
