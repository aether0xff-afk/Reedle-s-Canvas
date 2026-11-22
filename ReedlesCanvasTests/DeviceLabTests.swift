import PencilKit
import SwiftUI
import XCTest
@testable import ReedlesCanvas

@MainActor
final class DeviceLabTests: XCTestCase {
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
        XCTAssertTrue((json["frames"] as? [String: Any])?["sample_count"] as? Int ?? 0 > 0)
        #if targetEnvironment(simulator)
        XCTAssertEqual((json["environment"] as? [String: Any])?["is_simulator"] as? Bool, true)
        #endif
        let reopened = DeviceLabController(directory: root, sourceCommit: String(repeating: "a", count: 40))
        try await reopened.prepare()
        reopened.saveOperatorCheckpoint()
        let reopenedData = try XCTUnwrap(reopened.reportData)
        let reopenedJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: reopenedData) as? [String: Any])
        let validation = try XCTUnwrap(reopenedJSON["relaunch_checkpoint_validation"] as? [String: Any])
        XCTAssertEqual(validation["records_match"] as? Bool, true)
        XCTAssertEqual(validation["camera_matches"] as? Bool, true)
        XCTAssertEqual(validation["different_process"] as? Bool, false)
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
}
