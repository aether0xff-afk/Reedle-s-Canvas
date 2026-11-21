import Foundation

/// World coordinates grow right and down. Screen points are relative to the viewport's top left.
struct CanvasCamera: Equatable {
    static let minimumScale: CGFloat = 0.5
    static let maximumScale: CGFloat = 4

    let origin: CGPoint
    let scale: CGFloat

    init(origin: CGPoint, scale: CGFloat) {
        self.origin = origin
        self.scale = scale.isFinite && scale > 0 ? scale : 1
    }

    /// Scroll offsets are in screen points at the current zoom scale.
    init(contentOffset: CGPoint, scale: CGFloat) {
        let camera = CanvasCamera(origin: .zero, scale: scale)
        self.init(origin: camera.worldPoint(at: contentOffset), scale: camera.scale)
    }

    var contentOffset: CGPoint {
        CGPoint(x: origin.x * scale, y: origin.y * scale)
    }

    func worldPoint(at screenPoint: CGPoint) -> CGPoint {
        CGPoint(x: origin.x + screenPoint.x / scale,
                y: origin.y + screenPoint.y / scale)
    }

    func screenPoint(for worldPoint: CGPoint) -> CGPoint {
        CGPoint(x: (worldPoint.x - origin.x) * scale,
                y: (worldPoint.y - origin.y) * scale)
    }

    func screenRect(for worldRect: CGRect) -> CGRect {
        CGRect(origin: screenPoint(for: worldRect.origin),
               size: CGSize(width: worldRect.width * scale, height: worldRect.height * scale))
    }

    /// Dragging the content moves a fixed world point by the gesture's screen translation.
    func panned(by screenTranslation: CGPoint) -> CanvasCamera {
        let newOrigin = CGPoint(x: origin.x - screenTranslation.x / scale,
                                y: origin.y - screenTranslation.y / scale)
        return CanvasCamera(origin: newOrigin, scale: scale)
    }

    func zoomed(to requestedScale: CGFloat, around screenAnchor: CGPoint) -> CanvasCamera {
        guard requestedScale.isFinite, requestedScale > 0 else { return self }
        let newScale = min(max(requestedScale, Self.minimumScale), Self.maximumScale)
        let difference = 1 / scale - 1 / newScale
        let newOrigin = CGPoint(x: origin.x + screenAnchor.x * difference,
                                y: origin.y + screenAnchor.y * difference)
        return CanvasCamera(origin: newOrigin, scale: newScale)
    }
}

/// Interpolate magnification around one world point for the entire double tap.
struct CanvasZoomTransition {
    let start: CanvasCamera
    let targetScale: CGFloat
    let anchor: CGPoint

    func camera(at progress: CGFloat) -> CanvasCamera {
        if progress <= 0 { return start }
        if progress >= 1 { return start.zoomed(to: targetScale, around: anchor) }
        let endScale = min(max(targetScale, CanvasCamera.minimumScale), CanvasCamera.maximumScale)
        let eased = progress * progress * (3 - 2 * progress)
        let scale = start.scale * pow(endScale / start.scale, eased)
        return start.zoomed(to: scale, around: anchor)
    }
}
