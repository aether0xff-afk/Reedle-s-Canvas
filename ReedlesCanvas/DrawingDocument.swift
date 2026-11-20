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

    convenience init() {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.init(fileURL: directory.appendingPathComponent("drawing.pkdrawing"))
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
        do {
            drawing = try PKDrawing(data: Data(contentsOf: fileURL))
            strokeCount = drawing.strokes.count
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // First launch starts with an empty drawing.
        } catch {
            loadError = "원본 파일은 유지했습니다. 파일을 백업한 뒤 복구해 주세요."
        }
    }

    func attach(_ canvas: PKCanvasView) {
        self.canvas = canvas
        canvas.drawing = drawing
    }

    func drawingDidChange(_ canvas: PKCanvasView) {
        guard canvas === self.canvas else { return }
        drawing = canvas.drawing
        strokeCount = drawing.strokes.count
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        guard loadError == nil, let canvas else { return }
        // Keep edits in memory even if the write fails and the view is recreated.
        drawing = canvas.drawing
        do {
            let data = drawing.dataRepresentation()
            try data.write(to: fileURL, options: .atomic)
            saveError = nil
            showSaveError = false
        } catch {
            saveError = "필기 저장에 실패했습니다. 공간과 파일 권한을 확인해 주세요."
            showSaveError = true
        }
    }

    func detach(_ canvas: PKCanvasView) {
        guard canvas === self.canvas else { return }
        saveNow()
        self.canvas = nil
    }
}
