import PencilKit
import SwiftUI

@MainActor
private final class WorldCanvasView: PagedCanvasView {
    var viewportResized: (() -> Void)?
    private var lastSize: CGSize = .zero

    override func layoutSubviews() {
        super.layoutSubviews()
        if window != nil, lastSize != bounds.size {
            lastSize = bounds.size
            viewportResized?()
        }
    }
}

@MainActor
struct PencilCanvasView: UIViewRepresentable {
    @ObservedObject var document: DrawingDocument
    let navigation: CanvasNavigation

    func makeCoordinator() -> Coordinator {
        Coordinator(document: document, navigation: navigation)
    }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = WorldCanvasView()
        canvas.delegate = context.coordinator
        canvas.drawingPolicy = .pencilOnly
        canvas.tool = PKInkingTool(.pen, color: .black, width: 3)
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.contentSize = CGSize(width: CanvasWindow.side, height: CanvasWindow.side)
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.showsHorizontalScrollIndicator = false
        canvas.showsVerticalScrollIndicator = false
        canvas.minimumZoomScale = CanvasCamera.minimumScale
        canvas.maximumZoomScale = CanvasCamera.maximumScale
        canvas.bouncesZoom = false
        canvas.bounces = false
        document.attach(canvas)
        navigation.attach(canvas, document: document)
        canvas.viewportResized = { [weak canvas, weak navigation] in
            if let canvas { navigation?.viewportDidChange(canvas) }
        }

        let doubleTap = UITapGestureRecognizer(target: context.coordinator,
                                              action: #selector(Coordinator.zoomAtTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        doubleTap.cancelsTouchesInView = false
        canvas.addGestureRecognizer(doubleTap)
        canvas.panGestureRecognizer.addTarget(context.coordinator, action: #selector(Coordinator.gestureBegan(_:)))
        canvas.pinchGestureRecognizer?.addTarget(context.coordinator, action: #selector(Coordinator.gestureBegan(_:)))

        // A finger pans; Apple Pencil draws. The picker supplies pen and eraser tools.
        DispatchQueue.main.async { [weak canvas] in
            guard let canvas else { return }
            navigation.viewportDidChange(canvas)
            context.coordinator.toolPicker.addObserver(canvas)
            context.coordinator.toolPicker.setVisible(true, forFirstResponder: canvas)
            canvas.becomeFirstResponder()
        }
        return canvas
    }

    func updateUIView(_ uiView: PKCanvasView, context: Context) { }

    static func dismantleUIView(_ uiView: PKCanvasView, coordinator: Coordinator) {
        coordinator.navigation.detach(uiView)
        coordinator.document.detach(uiView)
        coordinator.toolPicker.removeObserver(uiView)
    }

    @MainActor
    final class Coordinator: NSObject, PKCanvasViewDelegate {
        let document: DrawingDocument
        let navigation: CanvasNavigation
        let toolPicker = PKToolPicker()

        init(document: DrawingDocument, navigation: CanvasNavigation) {
            self.document = document
            self.navigation = navigation
        }

        @objc func zoomAtTap(_ gesture: UITapGestureRecognizer) {
            guard let canvas = gesture.view as? PKCanvasView else { return }
            let point = gesture.location(in: canvas)
            navigation.zoom(at: CGPoint(x: point.x - canvas.bounds.minX,
                                        y: point.y - canvas.bounds.minY))
        }

        @objc func gestureBegan(_ gesture: UIGestureRecognizer) {
            if gesture.state == .began { navigation.stopZoom() }
        }

        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
            navigation.beginPencilInput(on: canvasView)
            document.beginToolInteraction()
        }

        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
            document.endToolInteraction()
            navigation.endPencilInput(on: canvasView)
            navigation.viewportDidChange(canvasView)
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            if let canvas = scrollView as? PKCanvasView { navigation.viewportDidChange(canvas) }
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            if let canvas = scrollView as? PKCanvasView { navigation.viewportDidChange(canvas) }
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            document.drawingDidChange(canvasView)
        }
    }
}
