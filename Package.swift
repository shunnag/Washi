// swift-tools-version: 6.0
// Washi — macOS ネイティブ技術だけで実装する EPUB 3 ツールキット。
// 依存パッケージゼロを設計原則とする。2 層のターゲットに分割する:
//   - WashiCore: 解析層(Foundation / Compression / CryptoKit / CoreGraphics /
//     ImageIO のみ)。OCF/OPF/nav 解析・メタデータ・本文抽出/検索・表紙デコード
//     まで。GUI セッションのないヘッドレス利用(CLI・索引・サーバ)で使える。
//   - Washi: 表示層(AppKit / WebKit を追加)。リフロー/FXL リーダービュー・
//     ページ census・サムネイル。WashiCore を @_exported 再輸出するので、
//     `import Washi` だけで両層の公開 API が見える(従来互換)。
// cooViewer から独立した MIT ライセンスのパッケージであり、単体で再利用できる。
import PackageDescription

let package = Package(
    name: "Washi",
    platforms: [
        // WKWebView.takeSnapshot / WKURLSchemeHandler / XMLDocument が揃う範囲で
        // できるだけ広く(cooViewer 本体は macOS 26+ だが、パッケージ単体は
        // 他アプリからの再利用を考慮して macOS 14+ とする)
        .macOS(.v14)
    ],
    products: [
        // 解析層のみ(ヘッドレス利用向け)
        .library(name: "WashiCore", targets: ["WashiCore"]),
        // 表示層込み(WashiCore を再輸出)
        .library(name: "Washi", targets: ["Washi"]),
        // cooViewer 用: Washi.framework を組み立てる材料の dylib。両ターゲットを
        // 1 つの動的ライブラリへまとめる(SwiftPM 利用者は上の automatic
        // ライブラリをそのまま使えばよい)。
        //
        // cooViewer の Scripts/build-washi-framework.sh との契約:
        //   - このプロダクトは Washi と WashiCore のちょうど 2 モジュールから成る。
        //     同スクリプトは `swift build --product WashiDynamic` の成果物から
        //     libWashiDynamic.dylib をコピーし、Washi / WashiCore の swiftmodule を
        //     名前で探して Modules/ へ据える。ターゲットを増やす、名前を変える、
        //     いずれかの target に `resources:` を足す場合は、このプロダクトと同
        //     スクリプトの両方を更新する(resource bundle は手組みの framework に
        //     含まれず、Bundle.module が実行時に落ちる)。
        //   - `unsafeFlags` は書かない。書くと依存パッケージとして使えなくなる。
        //     library evolution と module interface のフラグは同スクリプトと CI が
        //     `-Xswiftc` で渡す。
        //   - Release ビルドで各モジュールの .swiftinterface が .build 配下
        //     (ModuleCache 以外)から見つかること。同スクリプトと CI は場所を
        //     決め打ちせず .build 全体を検索する。
        .library(name: "WashiDynamic", type: .dynamic,
                 targets: ["WashiCore", "Washi"]),
    ],
    targets: [
        .target(
            name: "WashiCore",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .target(
            name: "Washi",
            dependencies: ["WashiCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "WashiTests",
            dependencies: ["Washi", "WashiCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        // 利用側と同じ公開 API だけを使い、@testable import の影響を避ける。
        .testTarget(
            name: "WashiPublicAPITests",
            dependencies: ["Washi"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
    ]
)
