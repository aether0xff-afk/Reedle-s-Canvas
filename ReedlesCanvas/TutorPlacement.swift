import Foundation

enum TutorPlacement {
    static func notice(size: CGSize, beside anchor: CGRect, camera: CanvasCamera,
                       obstacles: [CGRect], viewport: CGRect) -> CGRect? {
        let visible = camera.screenRect(for: anchor).intersection(viewport)
        guard !visible.isEmpty else { return nil }
        let occupied = obstacles.map(camera.screenRect(for:)).filter(viewport.intersects)
        return label(size: size, near: visible, toward: .nearRight, occupancy: occupied, inside: viewport)
    }

    static func label(size: CGSize, near anchor: CGRect, toward intent: TutorPlacementIntent,
                      occupancy: [CGRect], inside region: CGRect,
                      accepting canPlace: (CGRect) -> Bool = { _ in true }) -> CGRect? {
        let gap: CGFloat = 22
        guard size.width > 0, size.height > 0, region.width >= size.width,
              region.height >= size.height else { return nil }
        let horizontal = anchor.midX - size.width / 2
        let vertical = anchor.midY - size.height / 2
        let sides: [(TutorPlacementIntent, CGPoint)] = [
            (.nearRight, CGPoint(x: anchor.maxX + gap, y: vertical)),
            (.below, CGPoint(x: horizontal, y: anchor.maxY + gap)),
            (.nearLeft, CGPoint(x: anchor.minX - size.width - gap, y: vertical)),
            (.above, CGPoint(x: horizontal, y: anchor.minY - size.height - gap))
        ]
        let preferred: TutorPlacementIntent = intent == .onTarget ? .below : intent
        let candidates = sides.filter { $0.0 == preferred } + sides.filter { $0.0 != preferred }
        // Test short offsets on each side before searching farther from the anchor.
        for offset: CGFloat in [0, 32, -32, 64, -64, 96, -96] {
            for side in candidates {
                let alongY = side.0 == .nearLeft || side.0 == .nearRight
                let x = alongY ? side.1.x : min(max(side.1.x + offset, region.minX), region.maxX - size.width)
                let y = alongY ? min(max(side.1.y + offset, region.minY), region.maxY - size.height) : side.1.y
                let frame = CGRect(x: x, y: y,
                                   width: size.width, height: size.height)
                if region.contains(frame), !obstructs(frame, in: [anchor]),
                   !obstructs(frame, in: occupancy), canPlace(frame) { return frame }
            }
        }
        return nil
    }

    static func obstructs(_ frame: CGRect, in occupancy: [CGRect]) -> Bool {
        let padded = frame.insetBy(dx: -5, dy: -5)
        return occupancy.contains { padded.intersects($0) }
    }

    static func circleFrame(around anchor: CGRect) -> CGRect {
        let factor = CGFloat(2).squareRoot()
        // Enclose all four corners plus room for the two-point outline.
        let rx = max(anchor.width / 2 + 11, (anchor.width / 2 + 2) * factor)
        let ry = max(anchor.height / 2 + 11, (anchor.height / 2 + 2) * factor)
        return CGRect(x: anchor.midX - rx, y: anchor.midY - ry, width: 2 * rx, height: 2 * ry)
    }

    static func leader(from frame: CGRect, to anchor: CGRect, avoiding occupancy: [CGRect],
                       clearance: CGFloat = 4) -> [CGPoint] {
        let dx = anchor.midX - frame.midX, dy = anchor.midY - frame.midY
        let a = edge(of: frame, dx: dx, dy: dy, gap: 4)
        let b = edge(of: anchor, dx: -dx, dy: -dy, gap: 6)
        let blocked = occupancy.contains { crosses($0.insetBy(dx: -clearance, dy: -clearance), from: a, to: b) }
        return blocked ? [] : [a, b]
    }

    private static func crosses(_ rect: CGRect, from start: CGPoint, to end: CGPoint) -> Bool {
        var lower: CGFloat = 0
        var upper: CGFloat = 1
        let axes = [(start.x, end.x - start.x, rect.minX, rect.maxX),
                    (start.y, end.y - start.y, rect.minY, rect.maxY)]
        // Clip the segment's parameter range against each axis of the rectangle.
        for (origin, delta, minEdge, maxEdge) in axes {
            if delta == 0 {
                if origin < minEdge || origin > maxEdge { return false }
                continue
            }
            let a = (minEdge - origin) / delta
            let b = (maxEdge - origin) / delta
            lower = max(lower, min(a, b))
            upper = min(upper, max(a, b))
            if lower > upper { return false }
        }
        return true
    }

    private static func edge(of box: CGRect, dx: CGFloat, dy: CGFloat, gap: CGFloat) -> CGPoint {
        let distance = min((box.width / 2 + gap) / max(abs(dx), 0.001),
                           (box.height / 2 + gap) / max(abs(dy), 0.001))
        return CGPoint(x: box.midX + dx * distance, y: box.midY + dy * distance)
    }
}

struct TutorMark: Equatable, Identifiable {
    let annotation: TutorAnnotation
    let ink: TutorInk
    let frame: CGRect
    let leader: [CGPoint]
    var id: UUID { annotation.id }

    static func layout(_ annotations: [TutorAnnotation], anchors: [UUID: CGRect], in region: CGRect,
                       sizeOfLabel: (TutorInk) -> CGSize) -> [TutorMark] {
        var marks: [TutorMark] = []
        let studentInk = Array(anchors.values)
        for annotation in annotations {
            let action = annotation.action
            guard let anchor = anchors[action.targetID], let ink = action.ink else { continue }
            let otherInk = anchors.filter { $0.key != action.targetID }.map(\.value)
            let previous = marks.map(\.frame)
            let anchoredFrame: CGRect?
            switch ink {
            case .drawing(.circle):
                anchoredFrame = TutorPlacement.circleFrame(around: anchor)
            case .drawing(.underline):
                anchoredFrame = CGRect(x: anchor.minX, y: anchor.maxY + 7, width: anchor.width, height: 2)
            default:
                anchoredFrame = nil
            }
            if let anchoredFrame {
                guard region.contains(anchoredFrame),
                      !TutorPlacement.obstructs(anchoredFrame, in: otherInk + previous) else { continue }
                marks.append(TutorMark(annotation: annotation, ink: ink, frame: anchoredFrame, leader: []))
                continue
            }
            let size: CGSize
            switch ink {
            case .text, .math: size = sizeOfLabel(ink)
            case .drawing(.arrow): size = CGSize(width: 24, height: 24)
            case .drawing: size = CGSize(width: 126, height: 96)
            }
            let arrow = ink == .drawing(.arrow)
            let obstacles = otherInk + marks.filter {
                !(arrow && $0.annotation.action.targetID == action.targetID && $0.ink == .drawing(.circle))
            }.map(\.frame)
            func leader(for frame: CGRect) -> [CGPoint] {
                TutorPlacement.leader(from: frame, to: anchor, avoiding: obstacles, clearance: arrow ? 7 : 4)
            }
            let placementAnchor = marks.filter {
                $0.annotation.action.targetID == action.targetID && $0.ink == .drawing(.circle)
            }.reduce(anchor) { $0.union($1.frame) }
            let frame = TutorPlacement.label(size: size, near: placementAnchor, toward: action.intent,
                                             occupancy: studentInk + previous, inside: region) { box in
                !arrow || !leader(for: box).isEmpty
            }
            guard let frame else { continue }
            marks.append(TutorMark(annotation: annotation, ink: ink, frame: frame, leader: leader(for: frame)))
        }
        return marks
    }
}

struct TutorRevealSequence {
    private let markIDs: [UUID]
    private let secondsPerMark: TimeInterval = 0.46

    init(marks: [TutorMark], requestID: UUID) {
        markIDs = marks.filter { $0.annotation.requestID == requestID }.map(\.id)
    }

    var duration: TimeInterval { Double(markIDs.count) * secondsPerMark }

    func progress(for markID: UUID, elapsed: TimeInterval) -> CGFloat {
        guard let index = markIDs.firstIndex(of: markID) else { return 1 }
        return CGFloat(max(0, min(1, elapsed / secondsPerMark - Double(index))))
    }
}
