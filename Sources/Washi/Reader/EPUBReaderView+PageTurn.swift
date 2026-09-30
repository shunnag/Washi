import AppKit
import WebKit

/// EPUBReaderView のめくり演出: 項目内めくりと spine 遷移のカバー持ち越し、
/// カバーの回収(所有権・時間切れ)とスライド/フェードの演出本体。
extension EPUBReaderView {
    /// 項目内めくり + 演出。
    /// 順序が命: **旧ページのカバーを先に被せてから**めくり、新ページの
    /// スナップショットを取ってから演出に入る(めくり直後の新ページが
    /// 一瞬見えてから演出が始まる「チラつき」を構造的に排除する)。
    /// ホスト(delegate)がページカール等の独自演出で置き換えられる。
    /// 「視差効果を減らす」時・高速連打時・端到達時は演出なし
    func turnInDocAnimated(forward: Bool) {
        guard let webView else { return }
        let context = PageTurnContext(
            webView: webView, spineGeneration: spineLoadGeneration,
            navigationRequest: navigationRequestGeneration)
        let wantsAnimation = settings.pageTurnStyle != .none
            && !EPUBScreenMetrics.isScrolled(effectiveFlow)
            && allowsVisibleRenderingWork
            && !accessibilityShouldReduceMotion
            && Date().timeIntervalSince(turn.lastTurnDate) > 0.3
            // spine 読込中は演出を張らない: 章境界の重い読込中に再度めくると、
            // 読込中 webView のスナップショットでゴミカバーを作り pendingSpineTurn を
            // 上書きして画面を固着させる。演出なしの fast-path に降格することで
            // FXL のキーリピートめくりは従来どおり動く
            && !spineLoad.isLoadingSpineItem
        turn.lastTurnDate = Date()
        if isFixedLayoutItem {
            // FXL 項目は常に隣接 spine への移動。演出ありなら旧ページの
            // カバーを持ち越して spine 遷移演出(下の boundary 経路と同じ)
            if wantsAnimation {
                turn.lastAnimatedTurnTask = Task { [weak self] in
                    guard let self else { return }
                    await self.beginFXLSpineTurn(forward: forward, context: context)
                }
            } else {
                advanceSpine(forward: forward)
            }
            return
        }
        guard wantsAnimation else {
            evaluate("__washi.turnInDoc(\(forward));")
            return
        }
        turn.lastAnimatedTurnTask = Task { [weak self] in
            guard let self else { return }
            await self.performAnimatedTurn(forward: forward, context: context)
        }
    }

    private struct PageTurnContext {
        let webView: WKWebView
        let spineGeneration: Int
        let navigationRequest: UInt
    }

    private func canContinueTurn(_ context: PageTurnContext) -> Bool {
        !Task.isCancelled && allowsVisibleRenderingWork
            && context.webView === webView
            && context.spineGeneration == spineLoadGeneration
            && context.navigationRequest == navigationRequestGeneration
    }

    /// FXL 項目からの隣接 spine 移動をカバー持ち越しで演出する
    private func beginFXLSpineTurn(forward: Bool, context: PageTurnContext) async {
        guard canContinueTurn(context) else { return }
        let webView = context.webView
        let fast = WKSnapshotConfiguration()
        fast.afterScreenUpdates = false
        let oldWeb = try? await webView.takeSnapshot(configuration: fast)
        guard canContinueTurn(context) else { return }
        guard let oldWeb else {
            advanceSpine(forward: forward)
            return
        }
        // FXL でもレターボックス(余白)込みの全面でめくる(リフローと同じ扱い)
        let oldPage = composeFullPage(webImage: oldWeb, in: webView.frame)
        let cover = NSImageView(image: oldPage)
        cover.imageScaling = .scaleAxesIndependently
        cover.frame = bounds
        addSubview(cover, positioned: .above, relativeTo: webView)
        turn.turnOverlays.append(cover)
        updateFurnitureSuppression()
        // 既存の持ち越しカバー(前のめくりの旧ページ)を先に畳んでから上書きする。
        // 畳まないと旧カバーが所有権(pendingSpineTurn)を失って回収経路を全て
        // 失い、画面が旧ページで固着する
        clearPendingSpineTurn()
        turn.pendingSpineTurn = PendingSpineTurn(
            oldPage: oldPage, cover: cover, forward: forward)
        scheduleSpineTurnTimeout(for: cover)
        advanceSpine(forward: forward)
    }

    /// spine 遷移(章間・表紙→本文)もめくり演出で見せるための持ち越し状態。
    /// 境界めくり(turnInDoc が boundary)から次項目の表示完了までカバーで
    /// 旧ページを見せ続け、完了時に項目内めくりと同じ演出で切り替える
    struct PendingSpineTurn {
        let oldPage: NSImage
        let cover: NSImageView
        let forward: Bool
        /// false なら控えのカバー。新しいページが出た時点で演出なしに畳む
        var animated: Bool = true
    }

    /// turnOverlays を増減させた後に必ず呼ぶ(カバーの有無と抑制を同期)
    func updateFurnitureSuppression() {
        furnitureSuppressed = !turn.turnOverlays.isEmpty
    }

    /// カバー 1 枚を確実に回収する単一経路(旧: removeCover/timeout/clear に散っていた
    /// 除去を統合)。所有権(このカバーが現 pendingSpineTurn か)を判定して
    /// pending を壊さない。所有権を失って上書きされた孤児カバーもこれで畳める
    func foldTurnCover(_ cover: NSView) {
        let id = ObjectIdentifier(cover)
        turn.spineTurnTimeouts[id]?.cancel()  // 時間切れ回収タスクを止める
        turn.spineTurnTimeouts[id] = nil
        cover.removeFromSuperview()
        turn.turnOverlays.removeAll { $0 === cover }
        if turn.pendingSpineTurn?.cover === cover { turn.pendingSpineTurn = nil }
        updateFurnitureSuppression()
    }

    func clearPendingSpineTurn() {
        guard let pending = turn.pendingSpineTurn else { return }
        foldTurnCover(pending.cover)  // pending の nil 化・overlay 除去・timeout 停止を一括
    }

    /// テスト用: カバーを本番と同じ手順で turnOverlays に載せる(任意で pending 化)。
    /// 実 WKWebView 無しでカバーのライフサイクル(孤児回収・所有権)を検証するため
    func installTurnCover(_ cover: NSImageView, pending: Bool, forward: Bool = true,
                          animated: Bool = true) {
        addSubview(cover)
        turn.turnOverlays.append(cover)
        updateFurnitureSuppression()
        if pending {
            turn.pendingSpineTurn = PendingSpineTurn(
                oldPage: cover.image ?? NSImage(), cover: cover, forward: forward,
                animated: animated)
        }
    }

    /// 読み込みが来ないままカバーが残る事態(端で何も起きない・失敗、または
    /// 別のめくりに pendingSpineTurn を上書きされて所有権を失ったカバー)の安全弁。
    /// pendingSpineTurn 一致ではなく turnOverlays の membership で回収する
    func scheduleSpineTurnTimeout(for cover: NSImageView,
                                  after duration: Duration = .seconds(2)) {
        let task = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard let self, !Task.isCancelled,
                  self.turn.turnOverlays.contains(cover) else { return }
            self.foldTurnCover(cover)  // 所有権を問わず、まだ残っていれば畳む
        }
        turn.spineTurnTimeouts[ObjectIdentifier(cover)] = task
    }

    private func performAnimatedTurn(forward: Bool, context: PageTurnContext) async {
        guard canContinueTurn(context) else { return }
        let webView = context.webView
        // 1. 旧ページを撮り、カバーとして被せる(以後ユーザーには旧ページが
        //    見え続け、下でめくりが起きても分からない)
        let fast = WKSnapshotConfiguration()
        fast.afterScreenUpdates = false
        let oldWeb = try? await webView.takeSnapshot(configuration: fast)
        guard canContinueTurn(context) else { return }
        guard let oldWeb else {
            evaluate("__washi.turnInDoc(\(forward));")
            return
        }
        // 余白・ノンブル込みの全面(紙のページ全体)でめくる。本文領域だけを
        // 動かすと余白が静止して実際の本と違って見えるため、以降のカバーと
        // 演出はすべてビュー全面を対象にする
        let oldPage = composeFullPage(webImage: oldWeb, in: webView.frame)
        let cover = NSImageView(image: oldPage)
        cover.imageScaling = .scaleAxesIndependently
        cover.frame = bounds
        addSubview(cover, positioned: .above, relativeTo: webView)
        turn.turnOverlays.append(cover)
        updateFurnitureSuppression()

        // 2. カバーの下でめくる。境界なら次項目の表示完了までカバーを持ち越す
        //    (boundary 通知 → advanceSpine → runSetup 完了時に演出)。
        //    JS 呼び出しの**前に**登録する: boundary メッセージが戻り値より
        //    先に届いても loadSpineItem がカバーを保持できるように。
        //    代入前に旧 pending を畳む: 畳まないと前のめくりのカバーが所有権を
        //    失って回収経路を全て失い、画面が旧ページで固着する
        clearPendingSpineTurn()
        turn.pendingSpineTurn = PendingSpineTurn(
            oldPage: oldPage, cover: cover, forward: forward)
        let result = try? await webView.callAsyncJavaScript(
            "return __washi.turnInDoc(\(forward));",
            arguments: [:], in: nil, contentWorld: WashiContentWorld.world)
        switch result as? String {
        case "turned":
            guard canContinueTurn(context), turn.turnOverlays.contains(cover) else {
                foldTurnCover(cover)
                return
            }
            // await 中に別のめくり(B)が入って自分の pending を上書きしていたら、
            // B の境界持ち越しを壊さないよう自分が現 pending のときだけ nil にする
            if turn.pendingSpineTurn?.cover === cover { turn.pendingSpineTurn = nil }
        case "boundary":
            // 自分の境界遷移は spine 世代を進めるので、ここでは本と要求、
            // カバーの所有権を確認する。別の本・明示ジャンプには持ち越さない。
            guard webView === self.webView,
                  context.navigationRequest == navigationRequestGeneration,
                  turn.turnOverlays.contains(cover) else {
                foldTurnCover(cover)
                return
            }
            // カバーの後始末は advanceSpine / didReachBookEdge /
            // runSetup(表示完了)側、または所有権喪失時は timeout(foldTurnCover)が引き取る
            scheduleSpineTurnTimeout(for: cover)
            return
        default:
            // 'ignored'(setup 前)・nil(評価失敗): 何も起きないので畳む
            foldTurnCover(cover)
            return
        }

        // 3. 新ページを描画完了込みで撮り、演出でカバーを取り除く
        let after = WKSnapshotConfiguration()
        after.afterScreenUpdates = true
        // showPage は turnInDoc の返答前に pageChanged を post するため、
        // ここに来た時点でノンブルは新ページの値に更新済み(合成に正しく載る)
        let newWeb = try? await webView.takeSnapshot(configuration: after)
        guard canContinueTurn(context), turn.turnOverlays.contains(cover) else {
            foldTurnCover(cover)
            return
        }
        let newPage = newWeb.map { composeFullPage(webImage: $0, in: webView.frame) }
        runTurnEffect(oldPage: oldPage, newPage: newPage,
                      cover: cover, forward: forward)
    }

    /// めくり演出の本体(項目内・spine 遷移で共通)。
    /// ホスト独自演出(ページカール等)があれば委譲し、なければ内蔵の
    /// スライド/フェードでカバー(旧ページ)を取り除く
    func runTurnEffect(oldPage: NSImage, newPage: NSImage?,
                               cover: NSImageView, forward: Bool) {
        guard cover.superview === self, turn.turnOverlays.contains(cover) else { return }
        // 演出に入る前に、このカバーの時間切れ回収タスクを止める(membership 判定の
        // タイムアウトがスライド/フェード中に発火してカバーを途中で引き剥がさない)
        let coverID = ObjectIdentifier(cover)
        turn.spineTurnTimeouts[coverID]?.cancel()
        turn.spineTurnTimeouts[coverID] = nil
        func removeCover() { foldTurnCover(cover) }
        let removeCoverAfterAnimation: @Sendable () -> Void = {
            [weak self, weak cover] in
            Task { @MainActor [weak self, weak cover] in
                guard let self, let cover else { return }
                self.foldTurnCover(cover)
            }
        }
        // カバー・スナップショットとも全面合成なので演出矩形もビュー全面
        let frame = bounds
        if let newPage,
           delegate?.readerView(self, animatePageTurnFrom: oldPage, to: newPage,
                                forward: forward, in: frame) == true {
            removeCover()  // ホストのオーバーレイが被さっている
            return
        }
        guard cover.superview === self, turn.turnOverlays.contains(cover) else { return }
        switch settings.pageTurnStyle {
        case .slide:
            // 物理方向: 進む=旧ページが綴じの反対側へ抜ける
            // (右綴じで進む=右へ、左綴じで進む=左へ)
            let direction: CGFloat = (forward ? 1 : -1) * (isRTL ? 1 : -1)
            let target = cover.frame.offsetBy(dx: direction * frame.width, dy: 0)
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                cover.animator().frame = target
            }, completionHandler: removeCoverAfterAnimation)
        case .fade:
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.22
                cover.animator().alphaValue = 0
            }, completionHandler: removeCoverAfterAnimation)
        case .none:
            removeCover()
        }
    }
}
