import WebKit

@MainActor
enum WashiContentWorld {
    static let world = WKContentWorld.world(name: "washi")  // reader・census・thumbnail renderer・EPUBScrollDocument と共用
}
