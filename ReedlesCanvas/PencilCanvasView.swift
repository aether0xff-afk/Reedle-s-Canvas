import PencilKit
import SwiftUI

struct PencilCanvasView: UIViewRepresentable {
    @ObservedObject var document: DrawingDocument

    func makeCoordinator() -> Coordinator {
        Coordinator(document: document)
    }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.delegate = context.coordinator
        canvas.drawingPolicy = .pencilOnly
        canvas.tool = PKInkingTool(.pen, color: .black, width: 3)
        canvas.backgroundColor = .white
        canvas.contentSize = CGSize(width: 4096, height: 4096)
        canvas.minimumZoomScale = 0.5
        canvas.maximumZoomScale = 4
        document.attach(canvas)

        // A finger pans; Apple Pencil draws. The picker supplies pen and eraser tools.
        DispatchQueue.main.async { [weak canvas] in
            guard let canvas else { return }
            context.coordinator.toolPicker.addObserver(canvas)
            context.coordinator.toolPicker.setVisible(true, forFirstResponder: canvas)
            canvas.becomeFirstResponder()
        }
        return canvas
    }

    func updateUIView(_ uiView: PKCanvasView, context: Context) { }

    static func dismantleUIView(_ uiView: PKCanvasView, coordinator: Coordinator) {
        coordinator.document.detach(uiView)
        coordinator.toolPicker.removeObserver(uiView)
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        let document: DrawingDocument
        let toolPicker = PKToolPicker()

        init(document: DrawingDocument) {
            self.document = document
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            document.drawingDidChange(canvasView)
        }
    }
}
