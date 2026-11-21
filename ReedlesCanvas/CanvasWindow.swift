import Foundation

/// PencilKit draws in a finite local surface. Moving that surface through the
/// note keeps local coordinates small while the camera and stored ink stay in world space.
struct CanvasWindow {
    static let side: CGFloat = 16_384
    private(set) var origin = CGPoint.zero

    func worldCamera(offset: CGPoint, scale: CGFloat) -> CanvasCamera {
        let local = CanvasCamera(contentOffset: offset, scale: scale)
        return CanvasCamera(origin: CGPoint(x: origin.x + local.origin.x, y: origin.y + local.origin.y),
                            scale: local.scale)
    }

    func localOffset(for camera: CanvasCamera) -> CGPoint {
        CGPoint(x: (camera.origin.x - origin.x) * camera.scale,
                y: (camera.origin.y - origin.y) * camera.scale)
    }

    static func viewport(camera: CanvasCamera, size: CGSize) -> CGRect {
        CGRect(origin: camera.origin,
               size: CGSize(width: size.width / camera.scale, height: size.height / camera.scale))
    }

    mutating func centerIfNeeded(around viewport: CGRect) {
        let surface = CGRect(origin: origin, size: CGSize(width: Self.side, height: Self.side))
        let margin = Self.side / 8
        if !surface.insetBy(dx: margin, dy: margin).contains(viewport) {
            origin = CGPoint(x: (viewport.midX - Self.side / 2).rounded(.down),
                             y: (viewport.midY - Self.side / 2).rounded(.down))
        }
    }
}
