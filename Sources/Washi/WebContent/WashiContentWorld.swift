import WebKit

/// Washi の注入 JS が動く WKContentWorld。本のスクリプト(page world)から
/// 隔離されるので、`__washi` の関数や状態を著者スクリプトが書き換えたり
/// 観測したりできず、逆に Washi 側も本のグローバルを汚さない。
/// reader・census・thumbnail renderer・EPUBScrollDocument が同じ world を
/// 共用し、user script の注入と callAsyncJavaScript の両方でこれを指定する。
@MainActor
enum WashiContentWorld {
    static let world = WKContentWorld.world(name: "washi")
}
