import CryptoKit
import Foundation
import PencilKit

struct WorldStrokePoint {
    let position: CGPoint
    /// Nib dimensions before applying the stroke's affine transform.
    let nibSize: CGSize
    let force: CGFloat
    let timeOffset: TimeInterval
    let opacity: CGFloat
    let azimuth: CGFloat
    let altitude: CGFloat
}

struct WorldStroke: Identifiable {
    let id: UUID
    let source: PKStroke
    var worldOrigin: CGPoint = .zero

    var bounds: CGRect { source.renderBounds.offsetBy(dx: worldOrigin.x, dy: worldOrigin.y) }
    var createdAt: Date { source.path.creationDate }
    var ink: PKInk { source.ink }
    var visiblePathRanges: [ClosedRange<CGFloat>] { source.maskedPathRanges }

    /// Control points include masked portions. Use the mask or visible ranges for rendering and crops.
    var points: [WorldStrokePoint] {
        source.path.map { point in
            let local = point.location.applying(source.transform)
            return WorldStrokePoint(position: CGPoint(x: worldOrigin.x + local.x, y: worldOrigin.y + local.y),
                                    nibSize: point.size, force: point.force, timeOffset: point.timeOffset,
                                    opacity: point.opacity, azimuth: point.azimuth, altitude: point.altitude)
        }
    }
}

extension StrokeDescriptor {
    init(_ stroke: PKStroke) {
        let path = stroke.path
        let t = stroke.transform
        self.init(origin: StrokeOrigin(createdAt: path.creationDate, seed: stroke.randomSeed),
                  a: t.a, b: t.b, c: t.c, d: t.d, tx: t.tx, ty: t.ty, pointCount: path.count,
                  firstTime: path.first?.timeOffset ?? 0, lastTime: path.last?.timeOffset ?? 0)
    }
}

/// Reads the previous single-drawing format without modifying the original ink or sidecar.
enum LegacyStrokeCatalog {
    private struct Generation: Decodable {
        let digest: Data
        let ids: [UUID]
    }

    private struct IndexFile: Decodable {
        let version: Int
        let current: Generation
        let previous: Generation?
    }

    static func strokes(in drawing: PKDrawing, archive: Data, at url: URL) -> [WorldStroke] {
        let strokes = drawing.strokes
        let digest = Data(SHA256.hash(data: archive))
        let sidecar = url.appendingPathExtension("strokeids")
        let index = try? PropertyListDecoder().decode(IndexFile.self, from: Data(contentsOf: sidecar))
        let match = [index?.current, index?.previous].compactMap { $0 }.first {
            index?.version == 1 && $0.digest == digest && $0.ids.count == strokes.count
                && Set($0.ids).count == strokes.count
        }
        let ids = match?.ids ?? strokes.indices.map { recoveredID(digest: digest, index: $0) }
        return zip(ids, strokes).map { WorldStroke(id: $0.0, source: $0.1) }
    }
    private static func recoveredID(digest: Data, index: Int) -> UUID {
        var input = digest
        var number = UInt64(index).bigEndian
        withUnsafeBytes(of: &number) { input.append(contentsOf: $0) }
        var b = Array(SHA256.hash(data: input).prefix(16))
        b[6] = (b[6] & 0x0f) | 0x80
        b[8] = (b[8] & 0x3f) | 0x80
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}
