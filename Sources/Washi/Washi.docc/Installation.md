# 導入と最初の表示 / Installation and First Display

macOS 14 以降、Swift 6 を使う。ガイドとサンプルは Washi 1.22.0 の公開 API に対応する。
Washi は AppKit/WebKit を使う表示層、WashiCore は UI を使わない解析層。
両方とも第三者パッケージへの依存はない。

Use macOS 14+ and Swift 6. These guides and samples use the public API in Washi 1.22.0.
Washi provides AppKit/WebKit rendering; WashiCore provides parsing without UI.
Neither has third-party package dependencies.

## Xcode のアプリに追加する / Add to an Xcode app

1. **File → Add Package Dependencies…** を選び、
   `https://github.com/shunnag/Washi.git` を入力する。
2. **Up to Next Major Version: 1.22.0** を選ぶ。
3. 表示するアプリのターゲットに **Washi** を追加する。表紙・メタデータ・検索だけなら
   **WashiCore** を追加する。
4. アプリの Deployment Target を **macOS 14.0** 以降にする。
5. App Sandbox を使う場合は <doc:FileAccess> のファイル読み取り権限と、
   表示層に必要な **Outgoing Connections (Client)** を設定する。

Choose **File → Add Package Dependencies…**, enter the repository URL, and select
**Up to Next Major Version: 1.22.0**. Add **Washi** to the app target for rendering,
or **WashiCore** for covers, metadata, and search. Set the deployment target to macOS 14+.
For App Sandbox, configure the file access and WKWebView outgoing-connection entitlement
described in <doc:FileAccess>.

WashiDynamic はフレームワークを組み立てるホスト向けの別プロダクトで、通常の
アプリへの SwiftPM 導入では不要。

WashiDynamic is a separate product for hosts assembling a framework; normal SwiftPM
app integration does not require it.

## Package.swift で追加する / Configure Package.swift

依存の宣言だけでなく、使用するターゲットにプロダクトを追加する。

Declare both the package dependency and the product used by the consuming target.

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MyReader",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/shunnag/Washi.git", from: "1.22.0")
    ],
    targets: [
        .executableTarget(
            name: "MyReader",
            dependencies: [.product(name: "Washi", package: "Washi")]
        )
    ]
)
```

`Sources/MyReader/` にアプリの Swift ソースを置く。解析だけのプログラムでは、
上のプロダクトを `WashiCore` に変えて `import WashiCore` を使う。

Place your app's Swift sources under `Sources/MyReader/`. For a parsing-only program,
replace the product with `WashiCore` and use `import WashiCore`.

## 最初の表示 / First display

<doc:GettingStarted> に AppKit のコントローラー、<doc:SwiftUIIntegration> に
SwiftUI の例がある。ファイル選択から試す場合は、リポジトリの
[サンプル](https://github.com/shunnag/Washi/tree/main/Samples)を使う。
選択した URL のアクセス権については <doc:FileAccess> を先に確認する。

See <doc:GettingStarted> for an AppKit controller and <doc:SwiftUIIntegration> for
SwiftUI. Use the [standalone samples](https://github.com/shunnag/Washi/tree/main/Samples)
to try file selection through rendering. Review <doc:FileAccess> for URL access lifetime.
