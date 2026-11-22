import Foundation

struct DeviceLabFrameStats {
    let sampleCount: Int
    let p50Milliseconds: Double
    let p95Milliseconds: Double
    let maximumMilliseconds: Double

    init(intervals: [Double]) {
        let valid = intervals.filter { $0.isFinite && $0 > 0 }.sorted().map { $0 * 1_000 }
        sampleCount = valid.count
        func percentile(_ q: Double) -> Double {
            guard !valid.isEmpty else { return 0 }
            return valid[max(0, min(valid.count - 1, Int(ceil(q * Double(valid.count))) - 1))]
        }
        p50Milliseconds = percentile(0.5)
        p95Milliseconds = percentile(0.95)
        maximumMilliseconds = valid.isEmpty ? 0 : valid[valid.count - 1]
    }
}

enum DeviceLabBattery {
    static func endpoints(levels: [Double]) -> (start: Double, end: Double) {
        guard !levels.isEmpty else { return (-1, -1) }
        return (levels[0], levels[levels.count - 1])
    }

    static func canEstimateDrop(levels: [Double], unplugged: [Bool], seconds: Double) -> Bool {
        guard seconds.isFinite, seconds >= 600, levels.count >= 2, levels.count == unplugged.count else { return false }
        return unplugged.allSatisfy({ $0 })
            && levels.allSatisfy({ $0.isFinite && (0...1).contains($0) })
            && levels[levels.count - 1] <= levels[0]
    }
}
