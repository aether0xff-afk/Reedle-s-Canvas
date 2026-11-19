import Foundation
import PencilKit

/// This spike keeps the entire PKDrawing in one file. Entity IDs and world tiles come later.
@MainActor
final class DrawingDocument: ObservableObject {
    @Published private(set) var strokeCount = 0
    @Published private(set) var loadError: String?
    @Published var showSaveError = false
    @Published private(set) var saveError: String?

    private(set) var drawing = PKDrawing()
    private weak var canvas: PKCanvasView?
    private var pendingSave: DispatchWorkItem?
    private let fileURL: URL

    init() {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = directory.appendingPathComponent("drawing.pkdrawing")
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                drawing = try PKDrawing(data: Data(contentsOf: fileURL))
                strokeCount = drawing.strokes.count
            } catch {
                // Keep the unreadable file intact. Never silently replace it with a blank canvas.
                loadError = "원본 파일은 유지했습니다. 파일을 백업한 뒤 복구해 주세요."
            }
        }
    }

    func attach(_ canvas: PKCanvasView) {
        self.canvas = canvas
        canvas.drawing = drawing
    }

    func drawingDidChange(_ canvas: PKCanvasView) {
        strokeCount = canvas.drawing.strokes.count
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        guard loadError == nil, let canvas else { return }
        do {
            let data = canvas.drawing.dataRepresentation()
            try data.write(to: fileURL, options: .atomic)
            drawing = canvas.drawing
            saveError = nil
        } catch {
            saveError = "필기 저장에 실패했습니다. 공간과 파일 권한을 확인해 주세요."
            showSaveError = true
        }
    }
}
