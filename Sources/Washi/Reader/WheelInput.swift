import AppKit

enum WheelInput {
    // macOS の WebKit が非精密ホイールを DOM へ渡すときと同じ 1 行 = 40px。
    static let pixelsPerLine: CGFloat = 40
}
