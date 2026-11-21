import Foundation

struct StrokeOrderShift {
    let id: UUID
    let from: Int64
    let to: Int64
}

struct StrokeOrder {
    let visible: [UUID: Int64]
    let hiddenShifts: [StrokeOrderShift]
    let nextZ: Int64

    /// Drawing at the top, erasing and moving a stroke need only the resident page.
    /// An insertion between two visible strokes can also shift hidden strokes in that interval.
    init(edited: [UUID], oldVisible: [UUID: Int64], nextZ: Int64,
         allIndices: () throws -> [UUID: Int64]) rethrows {
        var indices: [UUID: Int64] = [:]
        var next = nextZ
        var last: Int64 = -1
        for id in edited {
            let z: Int64
            if let old = oldVisible[id] {
                z = old
            } else {
                guard next < .max else { break }
                z = next
                next += 1
            }
            guard z > last else { break }
            indices[id] = z
            last = z
        }
        if indices.count == edited.count {
            visible = indices
            hiddenShifts = []
            self.nextZ = next
            return
        }

        let global = try allIndices()
        let sorted = global.sorted { a, b in
            a.value == b.value ? a.key.uuidString < b.key.uuidString : a.value < b.value
        }
        let retained = Set(edited)
        var merged: [UUID] = []
        var cursor = edited.startIndex
        for (id, _) in sorted {
            guard oldVisible[id] != nil else {
                merged.append(id)
                continue
            }
            guard retained.contains(id) else { continue }
            // Fill each surviving visible slot with the next retained stroke in the edited
            // order, including any freshly inserted strokes immediately preceding it.
            while cursor < edited.endIndex {
                let replacement = edited[cursor]
                cursor += 1
                merged.append(replacement)
                if oldVisible[replacement] != nil { break }
            }
        }
        merged.append(contentsOf: edited[cursor...])
        indices.removeAll(keepingCapacity: true)
        var shifts: [StrokeOrderShift] = []
        for (index, id) in merged.enumerated() {
            let z = Int64(index)
            if retained.contains(id) {
                indices[id] = z
            } else if let old = global[id], old != z {
                shifts.append(StrokeOrderShift(id: id, from: old, to: z))
            }
        }
        visible = indices
        hiddenShifts = shifts
        // Undo can restore an older, sparse order even after this compaction.
        self.nextZ = max(nextZ, Int64(merged.count))
    }
}
