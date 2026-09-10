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
    /// 再生中の spine 項目(ホストが現在項目と突き合わせて古い章の再開を防ぐ)
    private(set) var spineIndex = 0
    /// 再生中の spine 項目(テストの観測点)
    var currentSpineIndex: Int { spineIndex }
    private var parIndex = 0
    /// 再生中の par 番号(テストの観測点)
    var currentParIndex: Int { parIndex }
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
            // One SMIL can describe several spine documents. Starting playback
            // from a later document must enter at its first par, not jump back
            // to par 0 in the earlier document.
            if let first = overlay.parallels.firstIndex(where: {
                spineIndex(forPar: $0, in: overlay) == index
            }) {
                parIndex = first
            } else if overlayWasIntroducedBefore(spineIndex: index) {
                // A malformed shared SMIL may omit this document entirely.
                // Do not fall back to an earlier document and pull the reader
                // backwards; there is no valid narration entry for this item.
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
        // A silent or unavailable-audio par also has a resumable position.
        // Recreate its advance timer instead of restarting the entire chapter.
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
        // A flat SMIL may contain tens of thousands of skipped pars. Do not
        // recurse through advancePar/startCurrentPar (or across spine items).
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
                // Stop if the user left the narrated chapter. This check is
                // made before any automatic navigation for this operation.
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
            // Navigate only after finding a playable par, not once per skipped
            // chapter. A delegate may stop/restart playback or replace the book.
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
        // Navigation and host callbacks must settle before audio starts. If a
        // callback supersedes this transition, no orphan player is left running.
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
        // If the user navigated away while this clip was playing, do not keep
        // narrating the old chapter or pull the view back on the next highlight.
        if let displayed = reader?.currentSpineIndex, displayed != spineIndex {
            finish()
            return
        }
        let previousAudio = overlay.parallels[parIndex].audioHref
        // Every transition passes the skip filter, including contiguous clips
        // in the same audio file. Only unskipped adjacent clips keep playing.
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
        // The state callback can load another book, restart playback or stop.
        // Do not deliver the old completion into that new operation.
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
        reader?.mediaOverlayHighlight(fragmentID: Self.fragment(of: par.textHref),
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
        let withoutFragment = href.split(separator: "#", maxSplits: 1,
                                         omittingEmptySubsequences: false)[0]
        guard !withoutFragment.isEmpty,
              let path = ContainerPath.resolve(base: overlay.basePath,
                                               href: String(withoutFragment))
        else { return nil }
        return publication.spineIndex(forContainerPath: path)
    }

    private static func fragment(of href: String?) -> String? {
        guard let href else { return nil }
        let parts = href.split(separator: "#", maxSplits: 1,
                               omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let fragment = String(parts[1])
        return fragment.removingPercentEncoding ?? fragment
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
