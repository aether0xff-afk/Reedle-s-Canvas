import CoreGraphics
import Foundation
import PDFKit

extension NotePDFImport {
    static func read(at url: URL) throws -> Self {
        let data = try coordinatedData(at: url)
        let source = try NotePDFSource(data: data)
        guard let document = PDFDocument(data: data), document.pageCount == source.pageCount else {
            throw NoteResourceError.invalidPDF
        }
        var pages: [Page] = []
        for index in 0..<source.pageCount {
            try Task.checkCancellation()
            let page = try autoreleasepool {
                let size = try NotePDFSource.displayedSize(of: source.page(at: index))
                guard let page = document.page(at: index) else { throw NoteResourceError.invalidPage }
                let characters = page.numberOfCharacters
                let text = if characters > Self.maximumPageTextBytes {
                    page.selection(for: NSRange(location: 0, length: Self.maximumPageTextBytes))?.string ?? ""
                } else {
                    page.string ?? ""
                }
                return Page(size: size, text: NoteResourceText.bounded(text, bytes: Self.maximumPageTextBytes))
            }
            pages.append(page)
        }
        return Self(title: url.deletingPathExtension().lastPathComponent, data: data, pages: pages)
    }

    private static func coordinatedData(at url: URL) throws -> Data {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var read: Result<Data, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { file in
            read = Result {
                let handle = try FileHandle(forReadingFrom: file)
                defer { try? handle.close() }
                let size = try handle.seekToEnd()
                guard size > 0 else { throw NoteResourceError.invalidPDF }
                guard size <= UInt64(Self.maximumFileBytes) else { throw NoteResourceError.fileTooLarge }
                try handle.seek(toOffset: 0)
                let data = try handle.read(upToCount: Self.maximumFileBytes + 1) ?? Data()
                guard data.count <= Self.maximumFileBytes else { throw NoteResourceError.fileTooLarge }
                guard data.count == Int(size) else { throw NoteResourceError.invalidPDF }
                return data
            }
        }
        if let coordinationError { throw coordinationError }
        guard let read else { throw NoteResourceError.invalidPDF }
        return try read.get()
    }
}

/// The immutable source remains vector artwork when written into a PDF context.
final class NotePDFSource {
    let byteCount: Int
    private let document: CGPDFDocument

    init(data: Data) throws {
        guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider) else {
            throw NoteResourceError.invalidPDF
        }
        guard document.isUnlocked else { throw NoteResourceError.lockedPDF }
        guard document.numberOfPages > 0 else { throw NoteResourceError.invalidPDF }
        guard document.numberOfPages <= NotePDFImport.maximumPages else { throw NoteResourceError.tooManyPages }
        self.document = document
        byteCount = data.count
    }

    var pageCount: Int { document.numberOfPages }

    func page(at index: Int) throws -> CGPDFPage {
        guard (0..<pageCount).contains(index), let page = document.page(at: index + 1) else {
            throw NoteResourceError.invalidPage
        }
        return page
    }

    static func displayedSize(of page: CGPDFPage) throws -> CGSize {
        let crop = page.getBoxRect(.cropBox).intersection(page.getBoxRect(.mediaBox))
        let rotation = page.rotationAngle
        guard !crop.isNull, crop.minX.isFinite, crop.minY.isFinite,
              rotation.isMultiple(of: 90), NotePDFImport.supports(crop.size) else {
            throw NoteResourceError.invalidPage
        }
        return rotation.isMultiple(of: 180) ? crop.size : CGSize(width: crop.height, height: crop.width)
    }

    static func drawMaterials(in region: CGRect, from store: NoteStore, context: CGContext) throws {
        let materials = Dictionary(grouping: try store.pdfPages(in: region), by: \.materialID)
        for (materialID, pages) in materials {
            try autoreleasepool {
                let source = try NotePDFSource(data: store.pdfData(for: materialID))
                for page in pages {
                    let frame = page.frame.offsetBy(dx: -region.minX, dy: -region.minY)
                    draw(try source.page(at: page.index), in: frame, context: context)
                }
            }
        }
    }

    /// Paint into a context whose origin is at the upper left, like canvas world coordinates.
    static func draw(_ page: CGPDFPage, in frame: CGRect, context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(frame)
        context.clip(to: frame)
        context.translateBy(x: frame.minX, y: frame.maxY)
        context.scaleBy(x: 1, y: -1)
        context.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: frame.size),
                                                      rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
    }
}
