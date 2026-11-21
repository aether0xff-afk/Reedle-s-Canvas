import CoreGraphics
import SwiftUI

@MainActor
final class NotePDFLibrary: ObservableObject {
    @Published private(set) var revision = 0
    private let rasterizer = NotePDFRasterizer()
    private weak var cachedStore: NoteStore?
    private var nearbyRegion: CGRect?
    private var nearbyPages: [NotePDFPage] = []

    func refreshPages() {
        nearbyRegion = nil
        nearbyPages = []
        revision &+= 1
    }

    func pages(in region: CGRect, from store: NoteStore) -> [NotePDFPage] {
        if cachedStore !== store || nearbyRegion?.contains(region) != true {
            let expanded = region.insetBy(dx: -region.width / 2, dy: -region.height / 2)
            guard let pages = try? store.pdfPages(in: expanded) else { return [] }
            cachedStore = store
            nearbyRegion = expanded
            nearbyPages = pages
        }
        return nearbyPages.filter { $0.frame.intersects(region) }
    }

    func thumbnail(for page: NotePDFPage, pixels: Int, in store: NoteStore) async throws -> CGImage {
        try await rasterizer.thumbnail(for: page, pixels: pixels, in: store)
    }
}

private actor NotePDFRasterizer {
    private let documents: NSCache<NSUUID, NotePDFSource> = {
        let cache = NSCache<NSUUID, NotePDFSource>()
        cache.countLimit = 2
        cache.totalCostLimit = 72 * 1024 * 1024
        return cache
    }()

    private let images: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.countLimit = 24
        cache.totalCostLimit = 24 * 1024 * 1024
        return cache
    }()

    func thumbnail(for page: NotePDFPage, pixels: Int, in store: NoteStore) throws -> CGImage {
        try Task.checkCancellation()
        let key = "\(page.id.uuidString):\(pixels)" as NSString
        if let existing = images.object(forKey: key) { return existing }
        let materialID = page.materialID as NSUUID
        let source: NotePDFSource
        if let existing = documents.object(forKey: materialID) {
            source = existing
        } else {
            source = try NotePDFSource(data: store.pdfData(for: page.materialID))
            documents.setObject(source, forKey: materialID, cost: source.byteCount)
        }
        let pdfPage = try source.page(at: page.index)
        let scale = CGFloat(pixels) / max(page.frame.width, page.frame.height)
        let width = max(1, Int((page.frame.width * scale).rounded()))
        let height = max(1, Int((page.frame.height * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw NoteResourceError.invalidPage
        }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        NotePDFSource.draw(pdfPage, in: CGRect(x: 0, y: 0, width: width, height: height), context: context)
        guard let image = context.makeImage() else { throw NoteResourceError.invalidPage }
        try Task.checkCancellation()
        images.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
        return image
    }
}

@MainActor
struct NotePDFCanvas: View {
    let document: DrawingDocument
    @ObservedObject var projection: CanvasProjection
    @ObservedObject var library: NotePDFLibrary
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { viewport in
            Color.clear
                .overlay {
                    if let store = document.store {
                        let camera = projection.camera
                        let world = CanvasWindow.viewport(camera: camera, size: viewport.size)
                        let pages = library.pages(in: world, from: store)
                        let pixelBudget = sqrt(8_000_000 / CGFloat(max(1, pages.count)))
                        ZStack {
                            ForEach(pages) { page in
                                let size = CGSize(width: page.frame.width * camera.scale,
                                                  height: page.frame.height * camera.scale)
                                let requested = max(size.width, size.height) * displayScale
                                let buckets = [128, 256, 512, 1024, 1536]
                                let requestedBucket = buckets.first { CGFloat($0) >= requested } ?? 1536
                                let bucket = buckets.last { $0 <= requestedBucket && CGFloat($0) <= pixelBudget }
                                    ?? max(1, Int(pixelBudget))
                                NotePDFSheetImage(page: page, store: store, library: library, pixels: bucket)
                                    .frame(width: size.width, height: size.height)
                                    .position(camera.screenPoint(for: CGPoint(x: page.frame.midX, y: page.frame.midY)))
                            }
                        }
                    }
                }
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

@MainActor
private struct NotePDFSheetImage: View {
    let page: NotePDFPage
    let store: NoteStore
    let library: NotePDFLibrary
    let pixels: Int
    @State private var image: CGImage?
    @State private var failed = false

    var body: some View {
        Rectangle()
            .fill(.white)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1).resizable()
                } else if failed {
                    Image(systemName: "doc.badge.exclamationmark")
                        .foregroundStyle(.secondary)
                }
            }
            .overlay { Rectangle().strokeBorder(.gray.opacity(0.32), lineWidth: 1) }
            .task(id: pixels) {
                do {
                    let rendered = try await library.thumbnail(for: page, pixels: pixels, in: store)
                    try Task.checkCancellation()
                    image = rendered
                    failed = false
                } catch is CancellationError {
                    return
                } catch {
                    failed = true
                }
            }
    }
}
