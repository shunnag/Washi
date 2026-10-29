import Darwin
import Foundation

/// 圧迫通知を共有する。開始時点でも sysctl を読み、通知前の圧迫を見落とさない。
@MainActor
final class CensusMemoryPressure {
    static let shared = CensusMemoryPressure()
    private let source: any DispatchSourceMemoryPressure
    private(set) var isUnderPressure: Bool

    private init() {
        var level: Int32 = 0
        var size = MemoryLayout.size(ofValue: level)
        let status = sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0)
        // 読めない環境は追加ホストを使わず保守的に扱う。
        isUnderPressure = status != 0 || level != 1
        source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isUnderPressure = !self.source.data.contains(.normal)
                    || self.source.data.contains(.warning) || self.source.data.contains(.critical)
            }
        }
        source.resume()
    }
}
