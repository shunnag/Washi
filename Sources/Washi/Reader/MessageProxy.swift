import WebKit

/// userContentController が handler を強参照するため、weak 中継で循環を断つ
@MainActor
final class MessageProxy: NSObject, WKScriptMessageHandler {
    weak var owner: EPUBReaderView?

    init(owner: EPUBReaderView) {
        self.owner = owner
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        owner?.handleScriptMessage(message.body)
    }
}
