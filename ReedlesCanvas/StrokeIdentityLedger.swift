import Foundation

/// PencilKit on iPadOS 17 exposes the creation date and texture seed, but not an editable UUID.
struct StrokeOrigin: Hashable {
    let createdAt: Date
    let seed: UInt32
}

struct StrokeDescriptor: Hashable {
    let origin: StrokeOrigin
    let a, b, c, d, tx, ty: CGFloat
    let pointCount: Int
    let firstTime, lastTime: TimeInterval
}

struct StrokeIdentityLedger {
    private struct Entry {
        let descriptor: StrokeDescriptor
        let id: UUID
    }

    private var active: [Entry] = []
    // Oldest first. A restored stroke can reclaim its UUID after undo or redo.
    private var removed: [Entry] = []

    mutating func restore(_ descriptors: [StrokeDescriptor], ids: [UUID]) {
        precondition(descriptors.count == ids.count)
        active = zip(descriptors, ids).map { Entry(descriptor: $0.0, id: $0.1) }
        removed.removeAll()
    }

    mutating func reconcile(_ descriptors: [StrokeDescriptor]) -> [UUID] {
        let candidates = active + removed.reversed()
        var exact: [StrokeDescriptor: [Int]] = [:]
        for index in candidates.indices.reversed() {
            exact[candidates[index].descriptor, default: []].append(index)
        }

        // Reserve unchanged strokes first, so a moved copy cannot steal another copy's ID.
        var consumed = Set<Int>()
        var matches = descriptors.map { descriptor -> Int? in
            let match = exact[descriptor]?.popLast()
            if let match { consumed.insert(match) }
            return match
        }
        var byOrigin: [StrokeOrigin: [Int]] = [:]
        for index in candidates.indices.reversed() where !consumed.contains(index) {
            byOrigin[candidates[index].descriptor.origin, default: []].append(index)
        }
        for index in matches.indices where matches[index] == nil {
            if let match = byOrigin[descriptors[index].origin]?.popLast() {
                matches[index] = match
                consumed.insert(match)
            }
        }

        var recentRemoved = removed.indices.compactMap { index in
            consumed.contains(candidates.count - 1 - index) ? nil : removed[index]
        }
        for index in active.indices where !consumed.contains(index) {
            recentRemoved.append(active[index])
        }
        removed = Array(recentRemoved.suffix(4_096))
        active = zip(descriptors, matches).map { descriptor, match in
            Entry(descriptor: descriptor, id: match.map { candidates[$0].id } ?? UUID())
        }
        return active.map(\.id)
    }
}
