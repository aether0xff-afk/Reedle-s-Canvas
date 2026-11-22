import CoreFoundation
import PencilKit
import SwiftUI
import XCTest
@testable import ReedlesCanvas

@MainActor
final class DeviceLabTests: XCTestCase {
    func testDiagnosticJSONPreservesNumericTypesAndNulls() throws {
        let data = try DeviceLabJSON.encode([
            "enabled": true, "one": NSNumber(value: 1), "missing": NSNull(),
            "camera": ["x": CGFloat(-100_000.25), "scale": CGFloat(0.6)],
            "samples": [["physical_footprint_bytes": UInt64.max, "battery_level": -1.0]],
            "signed": Int64.min, "empty_frames": ["sample_count": 0, "p95_ms": 0.0]])
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(value["enabled"] as? Bool, true)
        let one = try XCTUnwrap(value["one"] as? NSNumber)
        XCTAssertEqual(one.intValue, 1)
        XCTAssertNotEqual(CFGetTypeID(one), CFBooleanGetTypeID())
        XCTAssertTrue(value["missing"] is NSNull)
        XCTAssertEqual((value["camera"] as? [String: Any])?["x"] as? Double, -100_000.25)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(String(UInt64.max)))
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(String(Int64.min)))
    }

    func testInvalidDiagnosticValuesThrowCatchableErrorsWithTheirFieldPaths() throws {
        let invalidValues: [Any] = [Double.nan, Double.infinity, -Double.infinity, Date(), Optional<Int>.none as Any]
        for invalid in invalidValues {
            XCTAssertThrowsError(try DeviceLabJSON.encode(["samples": [["bad": invalid]]])) { error in
                XCTAssertTrue(error.localizedDescription.contains("$.samples[0].bad"), error.localizedDescription)
            }
        }
    }

    func testInvalidReportPreservesLastReportAndPersistsANonJSONFailureRecord() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = DeviceLabController(directory: root, sourceCommit: String(repeating: "a", count: 40))
        try controller.saveReport(["completed": false, "sequence": 1])
        let original = try XCTUnwrap(controller.reportData)
        XCTAssertThrowsError(try controller.saveReport(["frames": ["p95_ms": Double.nan]]))
        XCTAssertEqual(controller.reportData, original)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Results/report.json")), original)
        let message = try String(contentsOf: root.appendingPathComponent("Results/serialization-error.txt"), encoding: .utf8)
        XCTAssertTrue(message.contains("$.frames.p95_ms"))
        XCTAssertTrue(message.contains("stage=report"))
    }

    func testFrameMetricsUseObservedIntervalsAndIgnoreInvalidValues() {
        let stats = DeviceLabFrameStats(intervals: [0.01, 0.02, 0.03, .nan, -1, 0])
        XCTAssertEqual(stats.sampleCount, 3)
        XCTAssertEqual(stats.p50Milliseconds, 20, accuracy: 0.001)
        XCTAssertEqual(stats.p95Milliseconds, 30, accuracy: 0.001)
        XCTAssertEqual(stats.maximumMilliseconds, 30, accuracy: 0.001)
        XCTAssertEqual(DeviceLabFrameStats(intervals: []).sampleCount, 0)
    }

    func testBatteryNeedsEverySampleToBeUnpluggedAndKnown() {
        XCTAssertTrue(DeviceLabBattery.canEstimateDrop(levels: [0.8, 0.79], unplugged: [true, true], seconds: 600))
        XCTAssertFalse(DeviceLabBattery.canEstimateDrop(levels: [0.8, 0.79], unplugged: [true, false], seconds: 600))
        XCTAssertFalse(DeviceLabBattery.canEstimateDrop(levels: [0.8, -1], unplugged: [true, true], seconds: 600))
        XCTAssertFalse(DeviceLabBattery.canEstimateDrop(levels: [0.8, 0.79], unplugged: [true, true], seconds: 90))
    }

    func testBatteryEndpointsAreScalarJSONNumbersIncludingSingleSampleStartup() throws {
        for levels in [[], [-1.0], [0.22], [0.8, 0.79]] {
            let endpoints = DeviceLabBattery.endpoints(levels: levels)
            let data = try DeviceLabJSON.encode(["battery": ["start_level": endpoints.start, "end_level": endpoints.end]])
            let report = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let battery = try XCTUnwrap(report["battery"] as? [String: Any])
            XCTAssertEqual((battery["start_level"] as? NSNumber)?.doubleValue, levels.isEmpty ? -1 : levels[0])
            XCTAssertEqual((battery["end_level"] as? NSNumber)?.doubleValue, levels.isEmpty ? -1 : levels[levels.count - 1])
        }
    }

    func testTheObservedPredicateSearchFunctionIsRejectedWithoutCallingIt() {
        let levels = [0.8, 0.79]
        var called = false
        let capturedSearch: ((Double) throws -> Bool) throws -> Double? = { predicate in
            called = true
            return try levels.last(where: predicate)
        }
        XCTAssertThrowsError(try DeviceLabJSON.encode(["battery": ["end_level": capturedSearch]])) { error in
            XCTAssertTrue(error.localizedDescription.contains("$.battery.end_level"))
        }
        XCTAssertFalse(called)
    }

    func testIsolatedNativeWorkloadPersistsAllTenThousandStrokesAndReport() async throws {
        try await verifyWorkload(seconds: 0.5)
    }

    func testFullNinetySecondWorkloadSurvivesTheRealCameraStartAndLaterTransitions() async throws {
        try await verifyWorkload(seconds: 90)
    }

    private func verifyWorkload(seconds: Double) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = DeviceLabController(directory: root, sourceCommit: String(repeating: "a", count: 40))
        defer { controller.stop(reason: "test teardown") }
        try await controller.prepare()
        let document = try XCTUnwrap(controller.document)
        XCTAssertEqual(document.strokeCount, 10_000)
        let host = UIHostingController(rootView: DeviceLabView(controller: controller))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 768, height: 1024))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        controller.start(seconds: seconds)
        let initialReport = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(controller.reportData)) as? [String: Any])
        let initialBattery = try XCTUnwrap(initialReport["battery"] as? [String: Any])
        let initialSamples = try XCTUnwrap(initialReport["samples"] as? [[String: Any]])
        XCTAssertEqual(initialSamples.count, 1)
        let initialLevel = try XCTUnwrap(initialSamples[0]["battery_level"] as? NSNumber).doubleValue
        XCTAssertEqual((initialBattery["start_level"] as? NSNumber)?.doubleValue, initialLevel)
        XCTAssertEqual((initialBattery["end_level"] as? NSNumber)?.doubleValue, initialLevel)
        let deadline = Date().addingTimeInterval(seconds + 30)
        while controller.running && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(controller.running)
        let data = try XCTUnwrap(controller.reportData)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["completed"] as? Bool, true)
        let verification = try XCTUnwrap(json["verification"] as? [String: Any])
        XCTAssertEqual(verification["stroke_records_equal"] as? Bool, true)
        XCTAssertEqual(verification["reopened_stroke_count"] as? Int, 10_000)
        XCTAssertGreaterThanOrEqual(json["duration_seconds"] as? Double ?? 0, seconds)
        XCTAssertGreaterThan(json["applied_navigation_requests"] as? Int ?? 0, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Results/report.json").path))
        let runID = try XCTUnwrap(json["run_id"] as? String)
        let session = root.appendingPathComponent("Results/Sessions/\(runID)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.appendingPathComponent("report.json").path))
        let journal = try String(contentsOf: session.appendingPathComponent("diagnostics.jsonl"), encoding: .utf8)
        let phases = try journal.split(separator: "\n").map {
            try XCTUnwrap((JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])?["phase"] as? String)
        }
        XCTAssertTrue(phases.contains("navigation.begin"))
        XCTAssertTrue(phases.contains("viewport.end"))
        XCTAssertTrue(phases.contains("zoom.end"))
        XCTAssertTrue(phases.contains("camera.persist.end"))
        XCTAssertEqual(phases.last, "finish.end")
        XCTAssertTrue((json["frames"] as? [String: Any])?["sample_count"] as? Int ?? 0 > 0)
        #if targetEnvironment(simulator)
        XCTAssertEqual((json["environment"] as? [String: Any])?["is_simulator"] as? Bool, true)
        #endif
        let reopened = DeviceLabController(directory: root, sourceCommit: String(repeating: "a", count: 40))
        try await reopened.prepare()
        reopened.saveOperatorCheckpoint()
        XCTAssertTrue(reopened.prepareExport())
        let reopenedData = try XCTUnwrap(reopened.reportData)
        let reopenedJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: reopenedData) as? [String: Any])
        let validation = try XCTUnwrap(reopenedJSON["relaunch_checkpoint_validation"] as? [String: Any])
        XCTAssertEqual(validation["records_match"] as? Bool, true)
        XCTAssertEqual(validation["camera_matches"] as? Bool, true)
        XCTAssertEqual(validation["different_process"] as? Bool, false)
        XCTAssertTrue((reopenedJSON["diagnostic_journal"] as? String)?.contains("finish.end") == true)
        let report = XCTAttachment(data: reopenedData, uniformTypeIdentifier: "public.json")
        report.name = "device-lab-simulator-report"
        report.lifetime = .keepAlways
        add(report)
        try await Task.sleep(for: .milliseconds(150))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { context in
            window.layer.render(in: context.cgContext)
        }
        let screenshot = XCTAttachment(image: image)
        screenshot.name = "device-lab-native-screen"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testInterruptedRunsKeepSeparateReportsAndJournals() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = DeviceLabController(directory: root, sourceCommit: String(repeating: "a", count: 40))
        try await controller.prepare()
        for _ in 0..<2 {
            controller.start(seconds: 600)
            controller.stop(reason: "operator interruption in test; no workload pass claimed")
        }
        let sessions = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Results/Sessions"),
                                                                  includingPropertiesForKeys: nil)
        XCTAssertEqual(sessions.count, 2)
        for session in sessions {
            let data = try Data(contentsOf: session.appendingPathComponent("report.json"))
            let report = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(report["completed"] as? Bool, false)
            XCTAssertTrue(FileManager.default.fileExists(atPath: session.appendingPathComponent("diagnostics.jsonl").path))
        }
    }
}
