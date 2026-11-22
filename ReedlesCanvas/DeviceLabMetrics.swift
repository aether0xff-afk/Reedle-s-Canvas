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
        maximumMilliseconds = valid.last ?? 0
    }
}

enum DeviceLabBattery {
    static func canEstimateDrop(levels: [Double], unplugged: [Bool], seconds: Double) -> Bool {
        seconds.isFinite && seconds >= 600 && levels.count >= 2 && levels.count == unplugged.count
            && unplugged.allSatisfy { $0 } && levels.allSatisfy { $0.isFinite && (0...1).contains($0) }
            && levels.last! <= levels.first!
    }
}
