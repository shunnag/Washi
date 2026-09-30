import Foundation

/// ファイルのバイト列をディスクから読み込む方法。
///
/// How the file bytes are read from disk.
public enum EPUBReadStrategy: Sendable {
    /// OS が安全と判断した場合はファイルをメモリマップし、それ以外はメモリへ
    /// 読み込む(Foundation の `.mappedIfSafe`)。高速でメモリ消費が少ない既定値。
    ///
    /// Memory-map the file when the OS deems it safe, otherwise read it into
    /// memory (Foundation's `.mappedIfSafe`). Fast and low-memory; the default.
    case mappedIfSafe
    /// 常にファイル全体をメモリへ読み込み、メモリマップは使わない。状態が変わり
    /// やすいストレージや信頼できないストレージ上のファイルに適している。
    /// メモリマップによる読み取りでは、途中でファイルが切り詰められたり、
    /// ネットワークボリュームが切断されたりすると SIGBUS でクラッシュしうる。
    /// 信頼できないアップロードを扱うヘッドレス処理やサーバーではこちらを推奨。
    ///
    /// Always read the whole file into memory (never memory-map). Safer for
    /// files on volatile or untrusted storage — a mapped read can crash with
    /// SIGBUS if the file is truncated underneath it or a network volume drops.
    /// Prefer this in headless/server contexts processing untrusted uploads.
    case alwaysCopy

    var dataOptions: Data.ReadingOptions {
        switch self {
        case .mappedIfSafe: [.mappedIfSafe]
        case .alwaysCopy: []
        }
    }
}

/// EPUB を開くとき、または読み取るときに発生するエラー。
///
/// An error raised while opening or reading an EPUB.
public enum EPUBError: Error, Sendable, Equatable, LocalizedError {
    /// EPUB として認識できないファイル(ZIP でない、container.xml がない、など)。
    /// 関連値の文字列は、どの検証に失敗したかを示す。
    ///
    /// The file is not a recognizable EPUB (not a ZIP, no container.xml, …).
    /// The associated string names what failed the check.
    case notAnEPUB(String)
    /// 構造上必須のファイルを解析できなかった。関連値の文字列は、対象の
    /// ファイル名または具体的な不備を示す。
    ///
    /// A required structural file could not be parsed. The associated string
    /// names the file or the specific defect.
    case malformed(String)
    /// 指定されたリソースがコンテナ内に存在しない。
    ///
    /// The named resource does not exist in the container.
    case resourceNotFound(String)
    /// 指定されたリソースは存在するが、コンテナが読み取れなかった。
    /// `reason` はコンテナのバックエンドによる、人が読める英語の説明。
    ///
    /// The named resource exists, but the container could not read it.
    /// `reason` is an English, human-readable explanation from the container
    /// backend.
    case containerReadFailed(path: String, reason: String)
    /// Washi では復号できない方式の DRM で保護されたコンテンツ。
    /// `scheme` は検出した DRM の名称(例: "Readium LCP")。
    ///
    /// The content is DRM-protected with a scheme Washi cannot decrypt.
    /// `scheme` names the detected DRM (e.g. "Readium LCP").
    case drmProtected(scheme: String)

    public var errorDescription: String? {
        switch self {
        case .notAnEPUB(let detail):
            return "Not a valid EPUB: \(detail)"
        case .malformed(let detail):
            return "Malformed EPUB: \(detail)"
        case .resourceNotFound(let path):
            return "Resource not found in the EPUB: \(path)"
        case .containerReadFailed(let path, let reason):
            return "Could not read EPUB container resource \(path): \(reason)"
        case .drmProtected(let scheme):
            return "This book is DRM-protected (\(scheme)) and cannot be opened."
        }
    }
}
