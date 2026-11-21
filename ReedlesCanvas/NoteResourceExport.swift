import PencilKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct NoteResourceExport: FileDocument {
    static var readableContentTypes: [UTType] { [.pdf, .png] }

    let data: Data
    let contentType: UTType
    let filename: String

    private init(data: Data, contentType: UTType, filename: String) {
        self.data = data
        self.contentType = contentType
        self.filename = filename
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.init(data: data, contentType: configuration.contentType,
                  filename: configuration.file.preferredFilename ?? "캔버스")
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }

    @MainActor
    static func pdf(_ material: NotePDFMaterial, from document: DrawingDocument) throws -> Self {
        try document.flushPendingEdits()
        guard let store = document.store else { throw NoteResourceError.missingPDF }
        let pages = try store.pdfPages(for: material.id)
        let source = try NotePDFSource(data: store.pdfData(for: material.id))
        guard pages.count == source.pageCount, pages.count == material.pageCount,
              let first = pages.first else { throw NoteResourceError.missingPDF }

        let files = FileManager.default
        let url = files.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("pdf")
        defer { try? files.removeItem(at: url) }
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [kCGPDFContextTitle as String: material.title]
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: first.frame.size), format: format)
        var failure: Error?
        try renderer.writePDF(to: url) { pdf in
            for (index, page) in pages.enumerated() {
                do {
                    try autoreleasepool {
                        guard index == page.index else { throw NoteResourceError.invalidPage }
                        let original = try source.page(at: index)
                        let bounds = CGRect(origin: .zero, size: try NotePDFSource.displayedSize(of: original))
                        let drawing = try document.drawingForExport(in: page.frame)
                        let marks = try document.tutorMarksForExport(in: page.frame)
                        pdf.beginPage(withBounds: bounds, pageInfo: [:])
                        NotePDFSource.draw(original, in: bounds, context: pdf.cgContext)
                        drawInk(drawing, marks: marks, region: page.frame, in: bounds,
                                maximumScale: 2, context: pdf.cgContext)
                    }
                } catch {
                    failure = error
                    break
                }
            }
        }
        if let failure { throw failure }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard !data.isEmpty else { throw NoteResourceError.exportFailed }
        return Self(data: data, contentType: .pdf, filename: NoteResourceText.bounded(material.title, bytes: 200))
    }

    @MainActor
    static func image(from document: DrawingDocument) throws -> Self {
        guard let region = document.currentWorldViewport, !region.isEmpty,
              let store = document.store else { throw NoteResourceError.noViewport }
        let drawing = try document.drawingForExport(in: region)
        let marks = document.aiLayerVisible ? document.tutorMarks : []
        let bounds = CGRect(origin: .zero, size: region.size)
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = resolution(for: region, maximumScale: 4)
        format.preferredRange = .standard
        let renderer = UIGraphicsImageRenderer(size: bounds.size, format: format)
        var failure: Error?
        let png = renderer.pngData { bitmap in
            UIColor.white.setFill()
            bitmap.fill(bounds)
            do {
                try NotePDFSource.drawMaterials(in: region, from: store, context: bitmap.cgContext)
                drawInk(drawing, marks: marks, region: region, in: bounds,
                        maximumScale: 4, context: bitmap.cgContext)
            } catch {
                failure = error
            }
        }
        if let failure { throw failure }
        guard !png.isEmpty else { throw NoteResourceError.exportFailed }
        return Self(data: png, contentType: .png, filename: "리들의 캔버스")
    }

    @MainActor
    private static func drawInk(_ drawing: PKDrawing, marks: [TutorMark], region: CGRect,
                                in bounds: CGRect, maximumScale: CGFloat, context: CGContext) {
        let scale = resolution(for: region, maximumScale: maximumScale)
        if !drawing.strokes.isEmpty {
            drawing.image(from: CGRect(origin: .zero, size: region.size), scale: scale).draw(in: bounds)
        }
        if !marks.isEmpty {
            context.saveGState()
            defer { context.restoreGState() }
            context.clip(to: bounds)
            context.translateBy(x: bounds.minX, y: bounds.minY)
            context.scaleBy(x: bounds.width / region.width, y: bounds.height / region.height)
            TutorInkCanvas.draw(marks: marks, in: region, context: context)
        }
    }

    private static func resolution(for region: CGRect, maximumScale: CGFloat) -> CGFloat {
        min(maximumScale, 2_048 / max(region.width, region.height))
    }
}
