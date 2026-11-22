import CryptoKit
import Darwin
import PencilKit
import SwiftUI
import UniformTypeIdentifiers

/// Used by the separate device-test playground; the normal app entry does not open this view.
@MainActor
struct DeviceLabView: View {
    @StateObject private var controller: DeviceLabController
    @Environment(\.scenePhase) private var phase
    @State private var exporting = false

    init(controller: DeviceLabController) { _controller = StateObject(wrappedValue: controller) }

    init(sourceCommit: String) {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ReedleDeviceLab", isDirectory: true)
        self.init(controller: DeviceLabController(directory: directory, sourceCommit: sourceCommit))
    }

    var body: some View {
        VStack(spacing: 6) {
            Text("Reedle 실기기 검증 · 개인 노트와 분리됨").font(.headline)
            Text("검증 빌드: \(controller.sourceVersion)").font(.caption2)
            Text(controller.status).font(.caption).accessibilityIdentifier("deviceLab.status")
            ViewThatFits {
                controls
                ScrollView(.horizontal) { controls }
            }
            if let document = controller.document {
                ContentView(document: document, navigation: controller.navigation)
            } else { ProgressView("1만 획 시험 노트 준비 중") }
        }
        .task {
            do { try await controller.prepare() }
            catch { controller.status = "준비 실패: \(error.localizedDescription)" }
        }
        .onChange(of: phase) { _, value in controller.sceneChanged(active: value == .active) }
        .onDisappear { controller.stop(reason: "view disappeared") }
        .background {
            GeometryReader { geometry in
                Color.clear.onAppear { controller.recordSize(geometry.size) }
                    .onChange(of: geometry.size) { _, size in controller.recordSize(size) }
            }
        }
        .fileExporter(isPresented: $exporting,
                      document: DeviceLabJSONDocument(data: controller.reportData ?? Data()),
                      contentType: .json, defaultFilename: "Reedle-DeviceLab-report") { result in
            if case let .failure(error) = result { controller.status = "내보내기 실패: \(error.localizedDescription)" }
        }
    }

    private var controls: some View {
        HStack {
            Button("90초 자동 시험") { controller.start(seconds: 90) }.disabled(controller.running || controller.document == nil)
            Button("10분 배터리 시험") { controller.start(seconds: 600) }.disabled(controller.running || controller.document == nil)
            Button("중지") { controller.stop(reason: "operator stopped") }.disabled(!controller.running)
            Button("필기·복원 기준 저장") { controller.saveOperatorCheckpoint() }.disabled(controller.running || controller.document == nil)
            Button("결과 내보내기") { exporting = controller.prepareExport() }.disabled(controller.running || controller.reportData == nil)
        }.buttonStyle(.bordered).font(.caption)
    }
}

private struct DeviceLabJSONDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

@MainActor
final class DeviceLabController: NSObject, ObservableObject {
    @Published private(set) var document: DrawingDocument?
    @Published private(set) var running = false
    @Published private(set) var reportData: Data?
    @Published var status = "자동 시험 중에는 필기하지 마세요. 실제 Pencil 시험은 자동 시험 후 한 번 진행합니다."
    let navigation = CanvasNavigation()
    private let directory: URL
    private let sourceCommit: String
    var sourceVersion: String { String(sourceCommit.prefix(12)) }
    private var displayLink: CADisplayLink?
    private var startTime = 0.0, lastCallback = 0.0, lastSample = 0.0, plannedSeconds = 90.0
    private var intervals: [Double] = [], batteryLevels: [Double] = []
    private var workIntervals: [Double] = []
    private var appliedNavigationRequests = 0
    private var unplugged: [Bool] = [], memory: [[String: Any]] = []
    private var events: [[String: Any]] = []
    private var initialFingerprint = ""
    private var previousCheckpoint: [String: Any]?
    private var previousCheckpointMatches: Bool?
    private var previousCameraMatches: Bool?
    private var oldBatteryMonitoring = false
    private var runID: String?
    private var journalURL: URL?
    private var journalError: String?
    private var tracingNavigation = false
    private var tracedCluster: Int?
    private var tracedBelowUnitScale: Bool?
    private let fixtureCount = 10_000
    private var noteURL: URL { directory.appendingPathComponent("Note/drawing.pkdrawing") }
    private var reportURL: URL { directory.appendingPathComponent("Results/report.json") }
    private var checkpointURL: URL { directory.appendingPathComponent("checkpoint.json") }

    init(directory: URL, sourceCommit: String) {
        self.directory = directory
        self.sourceCommit = sourceCommit
    }

    func prepare() async throws {
        guard document == nil else { return }
        let folder = noteURL.deletingLastPathComponent()
        try await Task.detached(priority: .userInitiated) { try Self.seed(in: folder) }.value
        let opened = DrawingDocument(fileURL: noteURL)
        if let error = opened.loadError { throw NSError(domain: "DeviceLab", code: 1, userInfo: [NSLocalizedDescriptionKey: error]) }
        document = opened
        oldBatteryMonitoring = UIDevice.current.isBatteryMonitoringEnabled
        UIDevice.current.isBatteryMonitoringEnabled = true
        if let data = try? Data(contentsOf: checkpointURL),
           let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            previousCheckpoint = saved
            previousCheckpointMatches = saved["fingerprint"] as? String == (try fingerprint())
            let camera = try opened.store?.metadata().camera
            previousCameraMatches = saved["camera_x"] as? Double == camera.map { Double($0.origin.x) }
                && saved["camera_y"] as? Double == camera.map { Double($0.origin.y) }
                && saved["camera_scale"] as? Double == camera.map { Double($0.scale) }
        }
        if let data = try? Data(contentsOf: reportURL) { reportData = data }
    }

    func start(seconds: Double) {
        guard !running, let document, seconds.isFinite, seconds > 0, seconds <= 3_600 else { return }
        do {
            let identifier = UUID().uuidString
            runID = identifier
            let session = directory.appendingPathComponent("Results/Sessions/\(identifier)", isDirectory: true)
            try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
            journalURL = session.appendingPathComponent("diagnostics.jsonl")
            journalError = nil; tracedCluster = nil; tracedBelowUnitScale = nil
            navigation.diagnosticEvent = { [weak self] phase, camera in
                guard let self, self.tracingNavigation else { return }
                self.recordDiagnostic(phase, camera: camera)
            }
            recordDiagnostic("start.save.begin")
            document.saveNow()
            guard document.saveError == nil else { throw labError(document.saveError!) }
            recordDiagnostic("start.fingerprint.begin")
            initialFingerprint = try fingerprint()
            recordDiagnostic("start.fingerprint.end")
            if let journalError { throw labError(journalError) }
            UIDevice.current.isBatteryMonitoringEnabled = true
            intervals = []; workIntervals = []; appliedNavigationRequests = 0
            batteryLevels = []; unplugged = []; memory = []
            plannedSeconds = seconds
            startTime = CACurrentMediaTime(); lastCallback = 0; lastSample = -1
            running = true
            status = "자동 시험 실행 중 · \(Int(seconds))초 · 종료될 때까지 필기하지 마세요"
            sample(elapsed: 0)
            let link = CADisplayLink(target: self, selector: #selector(step(_:)))
            link.preferredFramesPerSecond = UIScreen.main.maximumFramesPerSecond
            displayLink = link
            link.add(to: .main, forMode: .common)
            try writeProgress(completed: false, reason: "running")
        } catch {
            displayLink?.invalidate(); displayLink = nil
            UIDevice.current.isBatteryMonitoringEnabled = oldBatteryMonitoring
            running = false; status = "시험 시작 실패: \(error.localizedDescription)"
        }
    }

    @objc private func step(_ link: CADisplayLink) {
        let now = CACurrentMediaTime(), elapsed = now - startTime
        let progress = elapsed / plannedSeconds
        if lastCallback > 0 {
            intervals.append(now - lastCallback)
            if progress > 0.1 && progress < 0.9 { workIntervals.append(now - lastCallback) }
        }
        lastCallback = now
        if progress > 0.1 && progress < 0.9 {
            let cluster = Int(elapsed / max(0.05, min(4, plannedSeconds / 10))) % 2
            let x = (cluster == 0 ? 0.0 : 100_000) + 450 * (sin(elapsed * 2.5) + 1)
            let y = (cluster == 0 ? 0.0 : -100_000) + 300 * (cos(elapsed * 1.8) + 1)
            let camera = CanvasCamera(origin: CGPoint(x: x, y: y), scale: 1.2 + 0.6 * sin(elapsed * 2))
            let belowUnitScale = camera.scale < 1
            // Trace the first camera, distant-region switches and crossings of scale 1.
            // All other display-link requests still execute the identical workload.
            tracingNavigation = tracedCluster != cluster || tracedBelowUnitScale != belowUnitScale
            if tracingNavigation { recordDiagnostic("navigation.begin", camera: camera) }
            navigation.go(to: camera)
            if navigation.projection.camera == camera { appliedNavigationRequests += 1 }
            if tracingNavigation { recordDiagnostic("navigation.end", camera: camera) }
            tracingNavigation = false
            tracedCluster = cluster; tracedBelowUnitScale = belowUnitScale
            if let journalError { finish(completed: false, reason: journalError); return }
        }
        if elapsed - lastSample >= 1 {
            sample(elapsed: elapsed)
            do { try writeProgress(completed: false, reason: "running") }
            catch { finish(completed: false, reason: "report write failed: \(error.localizedDescription)"); return }
        }
        if elapsed >= plannedSeconds { finish(completed: true, reason: "scheduled workload finished") }
    }

    func stop(reason: String) {
        if running { finish(completed: false, reason: reason) }
        displayLink?.invalidate(); displayLink = nil
        UIDevice.current.isBatteryMonitoringEnabled = oldBatteryMonitoring
    }

    func sceneChanged(active: Bool) {
        events.append(["kind": active ? "foreground" : "background", "uptime": ProcessInfo.processInfo.systemUptime])
        if !active { stop(reason: "app left foreground; partial run retained") }
    }

    func recordSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        events.append(["kind": "content_size", "width_points": size.width, "height_points": size.height,
                       "uptime": ProcessInfo.processInfo.systemUptime])
    }

    func saveOperatorCheckpoint() {
        do {
            document?.saveNow()
            guard document?.saveError == nil else { throw labError(document!.saveError!) }
            try writeCheckpoint()
            if let data = reportData,
               var report = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                report["operator_checkpoint"] = ["stroke_count": document?.strokeCount ?? 0,
                                                  "fingerprint": try fingerprint(), "events": events]
                if let matches = previousCheckpointMatches {
                    report["relaunch_checkpoint_validation"] = ["records_match": matches,
                        "camera_matches": previousCameraMatches ?? false,
                        "different_process": previousCheckpoint?["pid"] as? Int != Int(getpid()),
                        "source_matches": previousCheckpoint?["source_commit"] as? String == sourceCommit]
                }
                try saveReport(report)
            }
            status = "필기·카메라 기준 저장됨. 앱을 종료·재실행한 뒤 같은 버튼을 누르고 결과를 내보내세요."
        } catch { status = "기준 저장 실패: \(error.localizedDescription)" }
    }

    func prepareExport() -> Bool {
        do {
            guard let reportData,
                  var report = try JSONSerialization.jsonObject(with: reportData) as? [String: Any] else { return false }
            if let identifier = report["run_id"] as? String, UUID(uuidString: identifier) != nil {
                let journal = directory.appendingPathComponent("Results/Sessions/\(identifier)/diagnostics.jsonl")
                if FileManager.default.fileExists(atPath: journal.path) {
                    let data = try Data(contentsOf: journal)
                    guard data.count <= 1_000_000 else { throw labError("Diagnostic export exceeds the 1 MB journal limit") }
                    report["diagnostic_journal"] = String(decoding: data, as: UTF8.self)
                }
            }
            self.reportData = try encodeDiagnostics(report, stage: "export")
            return true
        } catch { status = "진단 결과 준비 실패: \(error.localizedDescription)"; return false }
    }

    private func finish(completed: Bool, reason: String) {
        displayLink?.invalidate(); displayLink = nil
        recordDiagnostic("finish.save.begin")
        sample(elapsed: CACurrentMediaTime() - startTime)
        document?.saveNow()
        do {
            recordDiagnostic("finish.end")
            let failure = document?.saveError ?? journalError
            let didComplete = completed && failure == nil
            try writeProgress(completed: didComplete, reason: failure ?? reason)
            if didComplete { try writeCheckpoint() }
            status = didComplete ? "자동 시험 완료. Pencil 필기·창 크기 변경·복귀 후 기준 저장과 결과 내보내기를 진행하세요." : "부분 결과 저장: \(failure ?? reason)"
        } catch { status = "결과 저장 실패: \(error.localizedDescription)" }
        running = false
        UIDevice.current.isBatteryMonitoringEnabled = oldBatteryMonitoring
    }

    private func sample(elapsed: Double) {
        lastSample = elapsed
        let device = UIDevice.current
        batteryLevels.append(Double(device.batteryLevel))
        unplugged.append(device.batteryState == .unplugged)
        var info = task_vm_info_data_t()
        let capacity = MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size
        var count = mach_msg_type_number_t(capacity)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        var value: [String: Any] = ["elapsed_seconds": elapsed,
                                  "loaded_strokes": document?.loadedStrokeCount ?? 0,
                                  "battery_level": Double(device.batteryLevel),
                                  "battery_unplugged": device.batteryState == .unplugged,
                                  "low_power": ProcessInfo.processInfo.isLowPowerModeEnabled,
                                  "thermal_state": ProcessInfo.processInfo.thermalState.rawValue]
        if result == KERN_SUCCESS { value["physical_footprint_bytes"] = info.phys_footprint }
        memory.append(value)
    }

    private func writeProgress(completed: Bool, reason: String) throws {
        let duration = max(0, CACurrentMediaTime() - startTime)
        let stats = DeviceLabFrameStats(intervals: intervals)
        let workStats = DeviceLabFrameStats(intervals: workIntervals)
        #if targetEnvironment(simulator)
        let simulator = true
        #else
        let simulator = false
        #endif
        var verification: [String: Any] = ["scope": "isolated fixture records, reopened SQLite store; not process termination"]
        if completed {
            let reopened = try NoteStore(url: noteURL.deletingPathExtension().appendingPathExtension("sqlite"))
            verification["reopened_stroke_count"] = try reopened.metadata().strokeCount
            let finalFingerprint = try fingerprint()
            verification["stroke_records_equal"] = document?.saveError == nil && initialFingerprint == finalFingerprint
        }
        var report: [String: Any] = [
            "schema_version": 1, "source_commit": sourceCommit, "fixture_strokes": fixtureCount,
            "run_id": runID ?? "unstarted",
            "completed": completed, "reason": reason, "duration_seconds": duration,
            "planned_seconds": plannedSeconds,
            "environment": ["is_simulator": simulator, "model": UIDevice.current.model,
                            "os_version": UIDevice.current.systemVersion,
                            "maximum_refresh_hz": UIScreen.main.maximumFramesPerSecond],
            "frames": ["sample_count": stats.sampleCount, "p50_ms": stats.p50Milliseconds,
                       "p95_ms": stats.p95Milliseconds, "max_ms": stats.maximumMilliseconds,
                       "scope": "CADisplayLink callback intervals; not independent FPS or physical Pencil latency"],
            "workload_frames": ["sample_count": workStats.sampleCount, "p50_ms": workStats.p50Milliseconds,
                                "p95_ms": workStats.p95Milliseconds, "max_ms": workStats.maximumMilliseconds],
            "applied_navigation_requests": appliedNavigationRequests,
            "peak_footprint_bytes": memory.compactMap { $0["physical_footprint_bytes"] as? UInt64 }.max() ?? 0,
            "battery": ["start_level": batteryLevels.first ?? -1, "end_level": batteryLevels.last ?? -1,
                        "all_samples_unplugged": !unplugged.isEmpty && unplugged.allSatisfy { $0 },
                        "drop_estimate_eligible": DeviceLabBattery.canEstimateDrop(levels: batteryLevels, unplugged: unplugged, seconds: duration),
                        "scope": "whole-device coarse battery level, not isolated app power"],
            "samples": memory, "events": events, "verification": verification,
            "diagnostics": ["journal": journalURL?.lastPathComponent ?? "unavailable",
                            "write_error": journalError ?? "none",
                            "scope": "sampled synchronous phase journal overhead is included; last phase narrows a boundary, not a crash cause"],
            "physical_pencil_latency": "not measured by software; operator/high-speed camera required"]
        if let matches = previousCheckpointMatches {
            report["previous_checkpoint"] = ["records_match": matches,
                "different_process": previousCheckpoint?["pid"] as? Int != Int(getpid()),
                "source_matches": previousCheckpoint?["source_commit"] as? String == sourceCommit]
        }
        try saveReport(report)
    }

    func saveReport(_ report: [String: Any]) throws {
        let data = try encodeDiagnostics(report, stage: "report")
        try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: reportURL, options: .atomic)
        if let journalURL {
            try data.write(to: journalURL.deletingLastPathComponent().appendingPathComponent("report.json"), options: .atomic)
        }
        reportData = data
    }

    private func recordDiagnostic(_ phase: String, camera: CanvasCamera? = nil) {
        guard let journalURL, journalError == nil else { return }
        var entry: [String: Any] = ["phase": phase, "source_commit": sourceCommit,
                                    "uptime": ProcessInfo.processInfo.systemUptime,
                                    "loaded_strokes": document?.loadedStrokeCount ?? 0,
                                    "applied_navigation_requests": appliedNavigationRequests]
        if let camera { entry["camera"] = ["x": camera.origin.x, "y": camera.origin.y, "scale": camera.scale] }
        do {
            var data = try encodeDiagnostics(entry, stage: "journal", prettyPrinted: false)
            data.append(0x0a)
            if !FileManager.default.fileExists(atPath: journalURL.path) {
                guard FileManager.default.createFile(atPath: journalURL.path, contents: nil) else {
                    throw labError("Cannot create persistent diagnostic journal")
                }
            }
            let file = try FileHandle(forWritingTo: journalURL)
            defer { try? file.close() }
            try file.seekToEnd()
            try file.write(contentsOf: data)
            try file.synchronize()
        } catch { journalError = "diagnostic journal write failed: \(error.localizedDescription)" }
    }

    private func writeCheckpoint() throws {
        guard let store = document?.store else { throw labError("No test note") }
        let camera = try store.metadata().camera
        let state: [String: Any] = ["fingerprint": try fingerprint(), "pid": Int(getpid()), "source_commit": sourceCommit,
                                  "camera_x": camera.origin.x, "camera_y": camera.origin.y, "camera_scale": camera.scale]
        try encodeDiagnostics(state, stage: "checkpoint").write(to: checkpointURL, options: .atomic)
    }

    private func encodeDiagnostics(_ object: [String: Any], stage: String, prettyPrinted: Bool = true) throws -> Data {
        do { return try DeviceLabJSON.encode(object, prettyPrinted: prettyPrinted) }
        catch {
            // This fallback must not use the JSON writer that just failed.
            let folder = journalURL?.deletingLastPathComponent() ?? reportURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let message = "source_commit=\(sourceCommit)\nstage=\(stage)\n\(error.localizedDescription)\n"
            try? Data(message.utf8).write(to: folder.appendingPathComponent("serialization-error.txt"), options: .atomic)
            throw error
        }
    }

    private func fingerprint() throws -> String {
        let store = try NoteStore(url: noteURL.deletingPathExtension().appendingPathExtension("sqlite"))
        var hash = SHA256()
        let metadata = try store.metadata()
        // Camera changes are expected during the workload. Checkpoint camera is checked separately.
        let region = CGRect(x: -1_000_000, y: -1_000_000, width: 2_000_000, height: 2_000_000)
        let rows = try store.strokes(in: region)
        guard rows.count == metadata.strokeCount else { throw labError("Test strokes outside the fixture measurement region") }
        for row in rows {
            hash.update(data: Data("\(row.id)|\(row.zIndex)|\(row.bounds)".utf8))
            hash.update(data: row.data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func labError(_ message: String) -> NSError {
        NSError(domain: "DeviceLab", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private nonisolated static func seed(in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = try NoteStore(url: folder.appendingPathComponent("drawing.sqlite"))
        guard try store.metadata().strokeCount == 0 else { return }
        let rows = (0..<10_000).map { n -> StoredStroke in
            autoreleasepool {
                let samples = (0..<6).map { i in
                    PKStrokePoint(location: CGPoint(x: i * 3, y: i * (n % 4)), timeOffset: Double(i) / 60,
                                  size: CGSize(width: 3, height: 3), opacity: 1, force: 0.6, azimuth: 0.5, altitude: 1)
                }
                let path = PKStrokePath(controlPoints: samples, creationDate: Date(timeIntervalSinceReferenceDate: 800_000_000 + Double(n)))
                let stroke = PKStroke(ink: PKInk(.pen, color: n < 5_000 ? .blue : .orange), path: path,
                                      transform: .identity, mask: nil)
                let cell = n % 5_000
                let origin = CGPoint(x: (n < 5_000 ? 0 : 100_000) + cell % 100 * 90 + 30,
                                     y: (n < 5_000 ? 0 : -100_000) + cell / 100 * 90 + 30)
                return StoredStroke(id: UUID(), bounds: stroke.renderBounds.offsetBy(dx: origin.x, dy: origin.y),
                                    zIndex: Int64(n), data: PKDrawing(strokes: [stroke]).dataRepresentation())
            }
        }
        try store.commit(upserts: rows)
    }
}
