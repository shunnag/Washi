import SwiftUI
import Washi

/// 同じセッションのビューを保持する SwiftUI アダプター。1 ウインドウに 1 セッションを使う。
/// A SwiftUI adapter retaining one reader per session. Use one session per window.
public struct ReaderSurface: NSViewRepresentable {
    private let session: ReaderSession

    public init(session: ReaderSession) { self.session = session }

    public func makeCoordinator() -> Coordinator { Coordinator(session) }

    public func makeNSView(context: Context) -> EPUBReaderView { session.reader }

    public func updateNSView(_ view: EPUBReaderView, context: Context) {
        // 本の読み込みは明示的な open 操作だけで行う。状態更新による再読み込みを避ける。
    }

    public static func dismantleNSView(_ view: EPUBReaderView, coordinator: Coordinator) {
        coordinator.session.close()
    }

    @MainActor
    public final class Coordinator {
        let session: ReaderSession
        init(_ session: ReaderSession) { self.session = session }
    }
}
