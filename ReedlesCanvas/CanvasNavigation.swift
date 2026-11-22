import PencilKit
import QuartzCore
import SwiftUI

@MainActor
final class CanvasProjection: ObservableObject {
    @Published private(set) var camera = CanvasCamera(origin: .zero, scale: 1)

    func update(_ position: CanvasCamera) {
        if camera != position { camera = position }
    }
}

@MainActor
final class CanvasNavigation: ObservableObject {
    @Published private(set) var bookmark: CanvasCamera?
    @Published private(set) var isUsingPencil = false
    let projection = CanvasProjection()
    // Opt-in device-lab tracing; the normal app leaves this nil.
    var diagnosticEvent: ((String, CanvasCamera) -> Void)?
    private weak var canvas: PKCanvasView?
    private weak var document: DrawingDocument?
    private var window = CanvasWindow()
    private var hasInitialCamera = false
    private var isUpdatingViewport = false
    private var panWasEnabled = true
    private var pinchWasEnabled = true
    private var transition: CanvasZoomTransition?
    private var displayLink: CADisplayLink?
    private var transitionStart: CFTimeInterval = 0
    private let zoomDuration: CFTimeInterval = 0.26

    func attach(_ canvas: PKCanvasView, document: DrawingDocument) {
        self.canvas = canvas
        self.document = document
        window = CanvasWindow()
        hasInitialCamera = false
    }

    func detach(_ canvas: PKCanvasView) {
        guard self.canvas === canvas else { return }
        stopZoom()
        endPencilInput()
        self.canvas = nil
        self.document = nil
    }

    func rememberPosition() {
        guard let canvas, !isUsingPencil else { return }
        stopZoom()
        bookmark = window.worldCamera(offset: canvas.contentOffset, scale: canvas.zoomScale)
    }

    func returnToPosition() {
        guard let bookmark else { return }
        go(to: bookmark)
    }

    func go(to camera: CanvasCamera) {
        guard let canvas, !isUsingPencil else { return }
        stopZoom()
        apply(camera, to: canvas)
    }

    func zoom(at viewportPoint: CGPoint) {
        guard let canvas, !isUsingPencil else { return }
        let camera = window.worldCamera(offset: canvas.contentOffset, scale: canvas.zoomScale)
        let nextScale: CGFloat = (transition?.targetScale ?? camera.scale) < 2 ? 2 : 1
        stopZoom()
        if UIAccessibility.isReduceMotionEnabled {
            apply(camera.zoomed(to: nextScale, around: viewportPoint), to: canvas)
            return
        }
        transition = CanvasZoomTransition(start: camera, targetScale: nextScale, anchor: viewportPoint)
        transitionStart = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(stepZoom(_:)))
        displayLink = link
        link.add(to: .main, forMode: .common)
    }

    @objc private func stepZoom(_ link: CADisplayLink) {
        guard let canvas, let transition, canvas.window != nil else {
            stopZoom()
            return
        }
        let progress = CGFloat((link.targetTimestamp - transitionStart) / zoomDuration)
        apply(transition.camera(at: progress), to: canvas)
        if progress >= 1 { stopZoom() }
    }

    func stopZoom() {
        displayLink?.invalidate()
        displayLink = nil
        transition = nil
    }

    func viewportDidChange(_ canvas: PKCanvasView) {
        guard canvas === self.canvas, canvas.window != nil, !isUsingPencil, !isUpdatingViewport else { return }
        let current = window.worldCamera(offset: canvas.contentOffset, scale: canvas.zoomScale)
        let camera = hasInitialCamera ? current : (document?.restoredCamera ?? CanvasCamera(origin: .zero, scale: 1))
        apply(camera, to: canvas)
    }

    private func apply(_ camera: CanvasCamera, to canvas: PKCanvasView) {
        guard let document, !isUpdatingViewport, canvas.bounds.width > 0, canvas.bounds.height > 0 else { return }
        isUpdatingViewport = true
        defer { isUpdatingViewport = false }

        let viewport = CanvasWindow.viewport(camera: camera, size: canvas.bounds.size)
        var nextWindow = window
        nextWindow.centerIfNeeded(around: viewport)
        diagnosticEvent?("viewport.begin", camera)
        guard document.updateViewport(viewport, surfaceOrigin: nextWindow.origin) else {
            diagnosticEvent?("viewport.rejected", camera)
            return
        }
        diagnosticEvent?("viewport.end", camera)
        window = nextWindow
        hasInitialCamera = true

        if canvas.zoomScale != camera.scale {
            diagnosticEvent?("zoom.begin", camera)
            canvas.setZoomScale(camera.scale, animated: false)
            canvas.layoutIfNeeded()
            diagnosticEvent?("zoom.end", camera)
        }
        let offset = window.localOffset(for: camera)
        // Leave native pan/pinch gestures alone when they already set this position.
        if abs(offset.x - canvas.contentOffset.x) > 0.0001 || abs(offset.y - canvas.contentOffset.y) > 0.0001 {
            diagnosticEvent?("offset.begin", camera)
            canvas.setContentOffset(offset, animated: false)
            diagnosticEvent?("offset.end", camera)
        }
        diagnosticEvent?("camera.persist.begin", camera)
        document.updateCamera(camera)
        projection.update(camera)
        diagnosticEvent?("camera.persist.end", camera)
    }

    func beginPencilInput(on canvas: PKCanvasView) {
        guard self.canvas === canvas, !isUsingPencil else { return }
        stopZoom()
        panWasEnabled = canvas.panGestureRecognizer.isEnabled
        pinchWasEnabled = canvas.pinchGestureRecognizer?.isEnabled ?? false
        canvas.panGestureRecognizer.isEnabled = false
        canvas.pinchGestureRecognizer?.isEnabled = false
        isUsingPencil = true
    }

    func endPencilInput() {
        guard isUsingPencil else { return }
        canvas?.panGestureRecognizer.isEnabled = panWasEnabled
        canvas?.pinchGestureRecognizer?.isEnabled = pinchWasEnabled
        isUsingPencil = false
    }

    func endPencilInput(on source: PKCanvasView) {
        guard source === canvas else { return }
        endPencilInput()
    }
}
