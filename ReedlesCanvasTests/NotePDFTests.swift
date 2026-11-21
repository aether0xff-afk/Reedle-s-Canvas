import PDFKit
import PencilKit
import UIKit
import XCTest
@testable import ReedlesCanvas

final class NotePDFTests: XCTestCase {
    @MainActor
    func testTwentyPagesExportWithSourceContentStudentInkAndTutorMarksAfterReopen() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let defaults = UserDefaults.standard
        let previousColor = defaults.object(forKey: TutorInkColor.defaultsKey)
        defaults.set(TutorInkColor.blue.rawValue, forKey: TutorInkColor.defaultsKey)
        defer { defaults.set(previousColor, forKey: TutorInkColor.defaultsKey) }
        let inputURL = folder.appendingPathComponent("Worksheet.pdf")
        try worksheet().write(to: inputURL)
        let source = try NotePDFImport.read(at: inputURL)
        XCTAssertEqual(source.pages.count, 20)
        XCTAssertEqual(source.pages[0].size, CGSize(width: 288, height: 204))
        XCTAssertEqual(source.pages[1].size, CGSize(width: 240, height: 320))

        let noteURL = folder.appendingPathComponent("drawing.pkdrawing")
        let document = DrawingDocument(fileURL: noteURL)
        let store = try XCTUnwrap(document.store)
        let viewport = CGRect(x: -2040, y: 5000, width: 580, height: 480)
        let material = try store.insertPDF(source, beside: viewport)
        let pages = try store.pdfPages(for: material.id)
        let canvas = PagedCanvasView()
        document.attach(canvas)
        for page in pages {
            XCTAssertTrue(document.updateViewport(page.frame, surfaceOrigin: page.frame.origin))
            canvas.drawing = PKDrawing(strokes: canvas.drawing.strokes + [penStroke()])
            document.drawingDidChange(canvas)
            let id = try XCTUnwrap(document.worldStrokes().last?.id)
            let context = try document.makeTutorContext(around: [id])
            let action = page.index.isMultiple(of: 2)
                ? TutorAction(id: UUID(), kind: .draw, targetID: id, intent: .onTarget, content: "underline")
                : TutorAction(id: UUID(), kind: .write, targetID: id, intent: .below,
                              content: #"\frac{x^2+1}{\sqrt{a_1}}"#)
            let response = TutorResponse(schemaVersion: 1, requestID: context.requestID, noteID: context.noteID,
                                         observedRevision: context.inkRevision, decision: .act, actions: [action])
            let proposal = try XCTUnwrap(TutorProposal.decode(JSONEncoder().encode(response), for: context,
                                                               model: "test", reason: "Review"))
            try document.approveTutorProposal(proposal)
            let capture = try XCTUnwrap(document.captureForTutor(manual: true))
            XCTAssertEqual(capture.context.entityIDs, [id])
            XCTAssertTrue(page.frame.contains(capture.crop))
            XCTAssertLessThanOrEqual(capture.png.count, TutorCapture.maximumImageBytes)
            let captured = try XCTUnwrap(UIImage(data: capture.png))
            XCTAssertEqual(try visibleColors(in: captured), [.green, .red],
                           "Tutor crop must include the worksheet and student ink on page \(page.index + 1)")
        }
        try document.flushPendingEdits()

        let reopened = DrawingDocument(fileURL: noteURL)
        let restored = try XCTUnwrap(reopened.store)
        let last = try XCTUnwrap(pages.last)
        XCTAssertEqual(try restored.searchResources("Worksheet 20").first?.frame, last.frame)
        XCTAssertEqual(try restored.pdfPages(for: material.id), pages)
        XCTAssertEqual(reopened.strokeCount, 20)
        XCTAssertTrue(reopened.updateViewport(last.frame, surfaceOrigin: last.frame.origin))
        let exported = try NoteResourceExport.pdf(material, from: reopened)
        let pdf = try XCTUnwrap(PDFDocument(data: exported.data))
        XCTAssertEqual(pdf.pageCount, 20)
        for (index, page) in pages.enumerated() {
            let result = try XCTUnwrap(pdf.page(at: index))
            XCTAssertEqual(result.bounds(for: .mediaBox).size, page.frame.size)
            let image = result.thumbnail(of: page.frame.size, for: .mediaBox)
            XCTAssertEqual(try visibleColors(in: image), [.green, .red, .blue], "PDF page \(index + 1)")
            if index == 0 {
                // The marker moves from upper left to upper right after the cropped page rotates 90°.
                let probe = CGPoint(x: image.size.width * 244 / 288, y: image.size.height * 24 / 204)
                let marker = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { _ in
                    image.draw(at: CGPoint(x: -probe.x, y: -probe.y))
                }
                XCTAssertEqual(try visibleColors(in: marker), [.green])
            }
        }

        let viewPNG = try NoteResourceExport.image(from: reopened)
        XCTAssertEqual(try visibleColors(in: XCTUnwrap(UIImage(data: viewPNG.data))), [.green, .red, .blue])
        reopened.setAILayerVisible(false)
        let hiddenPNG = try NoteResourceExport.image(from: reopened)
        XCTAssertEqual(try visibleColors(in: XCTUnwrap(UIImage(data: hiddenPNG.data))), [.green, .red])
    }

    @MainActor
    private func worksheet() throws -> Data {
        let bounds = CGRect(x: 0, y: 0, width: 240, height: 320)
        let raw = UIGraphicsPDFRenderer(bounds: bounds).pdfData { renderer in
            for number in 1...20 {
                renderer.beginPage()
                UIColor(red: 0.05, green: 0.8, blue: 0.1, alpha: 1).setFill()
                renderer.fill(CGRect(x: 28, y: 50, width: 24, height: 28))
                ("Worksheet \(number)" as NSString).draw(at: CGPoint(x: 46, y: 65),
                                                         withAttributes: [.font: UIFont.systemFont(ofSize: 15)])
            }
        }
        let pdf = try XCTUnwrap(PDFDocument(data: raw))
        let first = try XCTUnwrap(pdf.page(at: 0))
        first.setBounds(CGRect(x: 16, y: 12, width: 204, height: 288), for: .cropBox)
        first.rotation = 90
        return try XCTUnwrap(pdf.dataRepresentation())
    }

    @MainActor
    private func penStroke() -> PKStroke {
        let points = (0..<5).map { index in
            PKStrokePoint(location: CGPoint(x: 68 + index * 17, y: 100), timeOffset: Double(index) / 60,
                          size: CGSize(width: 8, height: 8), opacity: 1, force: 1, azimuth: 0,
                          altitude: .pi / 2)
        }
        let path = PKStrokePath(controlPoints: points, creationDate: Date())
        return PKStroke(ink: PKInk(.pen, color: .red), path: path)
    }

    private enum ColorChannel: Hashable { case green, red, blue }

    private func visibleColors(in image: UIImage) throws -> Set<ColorChannel> {
        let source = try XCTUnwrap(image.cgImage)
        let width = source.width, height = source.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        return try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: width, height: height,
                                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                                  space: CGColorSpaceCreateDeviceRGB(),
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
            var result = Set<ColorChannel>()
            for index in stride(from: 0, to: buffer.count, by: 4) {
                let r = Int(buffer[index]), g = Int(buffer[index + 1]), b = Int(buffer[index + 2])
                if g > 100 && g > r + 55 && g > b + 55 { result.insert(.green) }
                if r > 100 && r > g + 60 && r > b + 60 { result.insert(.red) }
                if b > 110 && b > r + 70 && b > g + 30 { result.insert(.blue) }
            }
            return result
        }
    }
}
