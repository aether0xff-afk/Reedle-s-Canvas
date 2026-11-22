import CoreText
import SwiftUI
import UIKit

@MainActor
struct TutorAnimationTiming {
    var date: @MainActor (Date) -> Date
    var sleep: @MainActor (TimeInterval) async throws -> Void

    static let system = Self(date: { $0 }, sleep: { seconds in
        try await Task.sleep(for: .seconds(seconds))
    })
}

@MainActor
struct TutorInkCanvas: View {
    @ObservedObject var document: DrawingDocument
    @ObservedObject var projection: CanvasProjection
    let pencilInUse: Bool
    let reduceMotion: Bool
    var timing = TutorAnimationTiming.system
    @AppStorage(TutorLetterSize.defaultsKey) private var letterSize = TutorLetterSize.standard
    @AppStorage(TutorInkColor.defaultsKey) private var inkColor = TutorInkColor.blue
    @State private var reveal: Reveal?

    private struct Reveal {
        let sequence: TutorRevealSequence
        let started: Date
    }

    static func labelSize(_ ink: TutorInk) -> CGSize {
        TutorTextLayout(ink, font: TutorLetterSize.saved.font)?.size ?? .zero
    }

    var body: some View {
        let marks = document.aiLayerVisible ? document.tutorMarks : []
        let layouts = Self.textLayouts(for: marks, font: letterSize.font)
        TimelineView(.animation(paused: reveal == nil)) { timeline in
            let date = timing.date(timeline.date)
            Canvas { context, size in
                context.withCGContext { cg in
                    Self.paint(marks, layouts: layouts, camera: projection.camera, size: size,
                               reveal: reveal, at: date, color: inkColor.color, in: cg)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: document.latestTutorRequest) {
            guard let request = document.latestTutorRequest, document.aiLayerVisible, !reduceMotion, !pencilInUse else {
                reveal = nil
                return
            }
            let sequence = TutorRevealSequence(marks: document.tutorMarks, requestID: request)
            guard sequence.duration > 0 else {
                reveal = nil
                return
            }
            reveal = Reveal(sequence: sequence, started: timing.date(.now))
            try? await timing.sleep(sequence.duration)
            if !Task.isCancelled { reveal = nil }
        }
        .onChange(of: pencilInUse) { _, active in if active { reveal = nil } }
        .onChange(of: reduceMotion) { _, enabled in if enabled { reveal = nil } }
        .onChange(of: document.aiLayerVisible) { _, visible in if !visible { reveal = nil } }
        .onChange(of: letterSize) { _, _ in document.relayoutTutor() }
    }

    static func draw(marks: [TutorMark], in region: CGRect, context: CGContext) {
        let layouts = textLayouts(for: marks, font: TutorLetterSize.saved.font)
        paint(marks, layouts: layouts, camera: CanvasCamera(origin: region.origin, scale: 1), size: region.size,
              color: TutorInkColor.saved.color, in: context)
    }

    private static func textLayouts(for marks: [TutorMark], font: UIFont) -> [UUID: TutorTextLayout] {
        var layouts: [UUID: TutorTextLayout] = [:]
        for mark in marks {
            layouts[mark.id] = TutorTextLayout(mark.ink, font: font)
        }
        return layouts
    }

    private static func paint(_ marks: [TutorMark], layouts: [UUID: TutorTextLayout], camera: CanvasCamera, size: CGSize,
                              reveal: Reveal? = nil, at date: Date = .now, color: UIColor, in context: CGContext) {
        let crop = CGRect(origin: .zero, size: size)
        for mark in marks {
            let progress = reveal.map { $0.sequence.progress(for: mark.id, elapsed: date.timeIntervalSince($0.started)) } ?? 1
            guard progress > 0 else { continue }
            let frame = camera.screenRect(for: mark.frame)
            let leader = mark.leader.map(camera.screenPoint(for:))
            let connectorBounds = leader.isEmpty ? CGRect.null : leader.reduce(frame) { bounds, point in
                bounds.union(CGRect(origin: point, size: CGSize(width: 1, height: 1)))
            }
            guard crop.intersects(frame) || crop.intersects(connectorBounds) else { continue }
            draw(mark.ink, frame: frame, leader: leader, scale: camera.scale, progress: progress,
                 layout: layouts[mark.id], color: color, in: context)
        }
    }

    private static func draw(_ ink: TutorInk, frame: CGRect, leader: [CGPoint], scale: CGFloat,
                             progress: CGFloat, layout: TutorTextLayout?, color: UIColor, in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(2 * scale)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        if leader.count == 2 {
            let connector = ink == .drawing(.arrow) ? arrow(leader[0], leader[1], scale: scale) : line(leader)
            context.addPath((progress < 1 ? connector.trimmedPath(from: 0, to: progress) : connector).cgPath)
            context.strokePath()
        }
        switch ink {
        case .text, .math:
            guard let layout else { return }
            context.clip(to: frame)
            context.translateBy(x: frame.minX, y: frame.minY)
            context.scaleBy(x: scale, y: scale)
            layout.draw(progress: progress, color: color.cgColor, in: context)
        case .drawing(let drawing):
            guard drawing != .arrow else { return }
            let path = shape(drawing, in: frame)
            context.addPath((progress < 1 ? path.trimmedPath(from: 0, to: progress) : path).cgPath)
            context.strokePath()
        }
    }

    private static func line(_ points: [CGPoint], closed: Bool = false) -> Path {
        Path { path in
            path.addLines(points)
            if closed { path.closeSubpath() }
        }
    }

    private static func arrow(_ start: CGPoint, _ end: CGPoint, scale: CGFloat) -> Path {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let size = min(11 * scale, hypot(end.x - start.x, end.y - start.y) / 2)
        let left = CGPoint(x: end.x - size * cos(angle - .pi / 6), y: end.y - size * sin(angle - .pi / 6))
        let right = CGPoint(x: end.x - size * cos(angle + .pi / 6), y: end.y - size * sin(angle + .pi / 6))
        return line([start, end, left, end, right])
    }

    private static func shape(_ drawing: TutorDrawing, in frame: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: frame.minX + x * frame.width, y: frame.minY + y * frame.height)
        }
        switch drawing {
        case .arrow: return Path()
        case .circle:
            return Path(ellipseIn: frame)
        case .underline: return line([point(0, 0.5), point(1, 0.5)])
        case .triangle: return line([point(0.1, 0.9), point(0.5, 0.12), point(0.9, 0.9)], closed: true)
        case .rectangle: return Path(CGRect(x: frame.minX + frame.width * 0.1, y: frame.minY + frame.height * 0.1,
                                            width: frame.width * 0.8, height: frame.height * 0.8))
        case .line, .parabola, .sine:
            let coordinates = (0...32).map { index -> CGPoint in
                let x = CGFloat(index) / 32
                let y: CGFloat
                switch drawing {
                case .line: y = 0.76 - 0.61 * x
                case .parabola: y = 0.76 - 0.61 * pow(x * 2 - 1, 2)
                default: y = 0.44 - 0.28 * sin(2 * .pi * x)
                }
                return point(0.1 + x * 0.8, y)
            }
            var path = line([point(0.1, 0.08), point(0.1, 0.84), point(0.94, 0.84)])
            path.addPath(line(coordinates))
            return path
        }
    }
}

private struct TutorTextLayout {
    private enum Piece {
        case glyphs(CTLine, baseline: CGPoint)
        case stroke([CGPoint], width: CGFloat)

        var revealCount: Int {
            switch self {
            case .glyphs(let line, _): return CTLineGetGlyphCount(line)
            case .stroke: return 1
            }
        }
    }

    private static let padding: CGFloat = 8
    private static let limit: CGFloat = 224
    private let pieces: [Piece]
    private let revealCount: Int
    let size: CGSize

    init?(_ ink: TutorInk, font: UIFont) {
        switch ink {
        case .text(let text): self.init(text: text, font: font)
        case .math(let formula): self.init(formula: formula, font: font)
        case .drawing: return nil
        }
    }

    private init(pieces: [Piece], width: CGFloat, height: CGFloat) {
        self.pieces = pieces
        revealCount = pieces.reduce(0) { $0 + $1.revealCount }
        size = CGSize(width: min(Self.limit, ceil(width) + 1) + 2 * Self.padding,
                      height: ceil(height) + 2 * Self.padding)
    }

    private static func styled(_ text: String, font: UIFont) -> CFAttributedString {
        let color = NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String)
        return NSAttributedString(string: text, attributes: [.font: font, color: true]) as CFAttributedString
    }

    private init(text: String, font: UIFont) {
        let styled = Self.styled(text, font: font)
        let typesetter = CTTypesetterCreateWithAttributedString(styled)
        let length = CFAttributedStringGetLength(styled)
        var pieces: [Piece] = []
        var offset = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
        while offset < length {
            let count = max(1, CTTypesetterSuggestLineBreak(typesetter, offset, Double(Self.limit)))
            let line = CTTypesetterCreateLine(typesetter, CFRange(location: offset, length: count))
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            let advance = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
            width = max(width, CGFloat(advance - CTLineGetTrailingWhitespaceWidth(line)))
            pieces.append(.glyphs(line, baseline: CGPoint(x: 0, y: height + max(ascent, font.ascender))))
            height += ceil(max(font.lineHeight, max(ascent, font.ascender) + descent + leading))
            offset += count
        }
        self.init(pieces: pieces, width: width, height: height)
    }

    private init(formula: TutorFormula, font: UIFont) {
        var lines: [String: [CGFloat: CTLine]] = [:]
        func line(_ text: String, _ size: CGFloat) -> CTLine {
            if let existing = lines[text]?[size] { return existing }
            let line = CTLineCreateWithAttributedString(Self.styled(text, font: font.withSize(size)))
            lines[text, default: [:]][size] = line
            return line
        }
        guard let layout = TutorFormulaLayout(formula, pointSize: font.pointSize, maximumWidth: Self.limit,
                                               measure: { text, size in
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            let advance = CTLineGetTypographicBounds(line(text, size), &ascent, &descent, nil)
            return .init(width: CGFloat(advance), ascent: ascent, descent: descent)
        }) else {
            self.init(text: formula.plainText, font: font)
            return
        }
        let pieces = layout.marks.map { mark -> Piece in
            switch mark {
            case .text(let text, let size, let baseline): return .glyphs(line(text, size), baseline: baseline)
            case .stroke(let points, let width): return .stroke(points, width: width)
            }
        }
        self.init(pieces: pieces, width: layout.size.width, height: layout.size.height)
    }

    func draw(progress: CGFloat, color: CGColor, in cg: CGContext) {
        var visible = Int(CGFloat(revealCount) * progress)
        cg.translateBy(x: Self.padding, y: Self.padding)
        cg.scaleBy(x: 1, y: -1)
        cg.setFillColor(color)
        cg.setStrokeColor(color)
        for piece in pieces where visible > 0 {
            switch piece {
            case .glyphs(let line, let position):
                let origin = CGPoint(x: position.x, y: -position.y)
                let count = min(visible, piece.revealCount)
                Self.drawGlyphs(line, first: count, at: origin, in: cg)
                visible -= count
            case .stroke(let points, let width):
                cg.beginPath()
                cg.addLines(between: points.map { CGPoint(x: $0.x, y: -$0.y) })
                cg.setLineWidth(width)
                cg.setLineCap(.round)
                cg.setLineJoin(.round)
                cg.strokePath()
                visible -= 1
            }
        }
    }

    private static func drawGlyphs(_ line: CTLine, first count: Int, at origin: CGPoint, in cg: CGContext) {
        guard count > 0 else { return }
        if count >= CTLineGetGlyphCount(line) {
            cg.textMatrix = .identity
            cg.textPosition = origin
            CTLineDraw(line, cg)
            return
        }
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { return }
        var remaining = count
        for run in runs where remaining > 0 {
            let count = min(remaining, CTRunGetGlyphCount(run))
            guard count > 0 else { continue }
            cg.textMatrix = .identity
            cg.textPosition = origin
            cg.saveGState()
            CTRunDraw(run, cg, CFRange(location: 0, length: count))
            cg.restoreGState()
            remaining -= count
        }
    }
}
