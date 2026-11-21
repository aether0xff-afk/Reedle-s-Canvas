import Darwin
import PencilKit
import SwiftUI

@main
struct M1CheckpointApp: App {
    var body: some Scene {
        WindowGroup { M1Checkpoint() }
    }
}

@MainActor
private struct M1Checkpoint: View {
    @State private var document: DrawingDocument?
    @State private var errorMessage: String?
    @StateObject private var navigation = CanvasNavigation()

    var body: some View {
        Group {
            if let document {
                VStack(spacing: 0) {
                    CheckpointControls(document: document, navigation: navigation)
                    ContentView(document: document, navigation: navigation)
                }
            } else if let errorMessage {
                Text(errorMessage)
            } else {
                ProgressView("통합 테스트 노트 여는 중")
            }
        }
        .task {
            guard document == nil else { return }
            do {
                let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("ReedleM1Checkpoint-v1", isDirectory: true)
                let inks = [PKInk(.pen, color: .blue), PKInk(.marker, color: .orange)]
                try await Task.detached(priority: .userInitiated) {
                    try Self.openFixture(in: folder, inks: inks)
                }.value
                document = DrawingDocument(fileURL: folder.appendingPathComponent("drawing.pkdrawing"))
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private nonisolated static func mark(_ n: Int, ink: PKInk, origin: CGPoint) -> StoredStroke {
        let samples = (0..<6).map { step -> PKStrokePoint in
            let width = CGFloat(2 + n % 3)
            return PKStrokePoint(location: CGPoint(x: step * 3, y: step * (n % 4)), timeOffset: Double(step) / 60,
                                 size: CGSize(width: width, height: width), opacity: 1,
                                 force: CGFloat(step + 1) / 6, azimuth: 0.5, altitude: 1)
        }
        let date = Date(timeIntervalSinceReferenceDate: 800_000_000 + Double(n))
        let stroke = PKStroke(ink: ink, path: PKStrokePath(controlPoints: samples, creationDate: date),
                              transform: .identity, mask: nil)
        return StoredStroke(id: UUID(), bounds: stroke.renderBounds.offsetBy(dx: origin.x, dy: origin.y),
                            zIndex: Int64(n),
                            data: PKDrawing(strokes: [stroke]).dataRepresentation())
    }

    private nonisolated static func openFixture(in folder: URL, inks: [PKInk]) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = try NoteStore(url: folder.appendingPathComponent("drawing.sqlite"))
        let metadata = try store.metadata()
        guard metadata.revision == 0, metadata.strokeCount == 0 else { return }
        let rows = (0..<10_000).map { n -> StoredStroke in
            let cluster = n / 5_000
            let cell = n % 5_000
            let x = (cluster == 0 ? 0 : 100_000) + (cell % 100) * 90 + 30
            let y = (cluster == 0 ? 0 : -100_000) + (cell / 100) * 90 + 30
            return autoreleasepool { mark(n, ink: inks[cluster], origin: CGPoint(x: x, y: y)) }
        }
        // Seed in one transaction so an interrupted first launch can retry cleanly.
        try store.commit(upserts: rows)
    }
}

@MainActor
private struct CheckpointControls: View {
    @ObservedObject var document: DrawingDocument
    let navigation: CanvasNavigation
    @Environment(\.scenePhase) private var phase
    @State private var lastLoadMilliseconds: Int?
    @State private var footprintMiB: Int?

    var body: some View {
        HStack {
            Text("M1 · 로드 \(document.loadedStrokeCount) / 전체 \(document.strokeCount)")
                .font(.caption.monospacedDigit())
            if let lastLoadMilliseconds {
                Text("구역 로드 \(lastLoadMilliseconds)ms")
                    .font(.caption.monospacedDigit())
            }
            if let footprintMiB {
                Text("\(footprintMiB) MiB")
                    .font(.caption.monospacedDigit())
                    .accessibilityLabel("앱 메모리 \(footprintMiB) 메비바이트")
            }
            Spacer()
            Button("A 구역") { go(to: .zero) }
            Button("B 구역") { go(to: CGPoint(x: 100_000, y: -100_000)) }
        }
        .padding(.horizontal)
        .buttonStyle(.bordered)
        .disabled(document.loadError != nil || phase != .active)
    }

    private func go(to origin: CGPoint) {
        let start = ProcessInfo.processInfo.systemUptime
        navigation.go(to: CanvasCamera(origin: origin, scale: 1))
        lastLoadMilliseconds = Int(((ProcessInfo.processInfo.systemUptime - start) * 1_000).rounded())
        // Sample on explicit region jumps, outside the timed navigation call.
        var info = task_vm_info_data_t()
        let capacity = MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size
        var count = mach_msg_type_number_t(capacity)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        footprintMiB = result == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : nil
    }
}
