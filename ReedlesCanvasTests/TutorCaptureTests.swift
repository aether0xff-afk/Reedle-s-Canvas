import Foundation
import XCTest
#if !os(Linux)
@testable import ReedlesCanvas
#endif

final class TutorCaptureTests: XCTestCase {
    func testNearbyEditsMergeAndDistantEditsStayLocal() throws {
        var edits = TutorDirtyRegion()
        let viewport = CGRect(x: -2_000, y: -2_000, width: 4_000, height: 4_000)
        edits.record(CGRect(x: 90, y: 90, width: 18, height: 24))
        edits.record(CGRect(x: 132, y: 90, width: 17, height: 24))
        XCTAssertEqual(edits.bounds, CGRect(x: 90, y: 90, width: 59, height: 24))
        let target = CGRect(x: 1100, y: 1100, width: 20, height: 20)
        edits.record(target)
        let crop = try XCTUnwrap(edits.crop(in: viewport))
        XCTAssertTrue(viewport.contains(crop))
        XCTAssertTrue(crop.contains(target))
        XCTAssertLessThanOrEqual(crop.width, 640)
        XCTAssertLessThanOrEqual(crop.height, 480)
        XCTAssertFalse(crop.intersects(CGRect(x: 90, y: 90, width: 59, height: 24)))
        XCTAssertNil(edits.crop(in: CGRect(x: 0, y: 0, width: 500, height: 500)))
    }

    func testCropUsesOnlyOnScreenIntersectionAndNormalizesVisibleStroke() throws {
        let viewport = CGRect(x: -100_000, y: 80_000, width: 850, height: 640)
        var edits = TutorDirtyRegion()
        edits.record(CGRect(x: -100_008, y: 80_007, width: 25, height: 28))
        let crop = try XCTUnwrap(edits.crop(in: viewport))
        XCTAssertEqual(crop.minX, viewport.minX)
        let entity = try XCTUnwrap(TutorCropEntity(id: UUID(), bounds: try XCTUnwrap(edits.bounds), in: crop))
        XCTAssertEqual(entity.x, 0)
        XCTAssertEqual(entity.width, 17 / crop.width, accuracy: 0.000001)
        XCTAssertLessThanOrEqual(entity.x + entity.width, 1)
        XCTAssertLessThanOrEqual(entity.y + entity.height, 1)
        let world = entity.worldBounds(in: crop)
        XCTAssertEqual(world.minX, viewport.minX, accuracy: 0.000001)
        XCTAssertEqual(world.minY, 80_007, accuracy: 0.000001)
        XCTAssertEqual(world.width, 17, accuracy: 0.000001)
        XCTAssertNil(TutorCropEntity(id: UUID(), bounds: CGRect(x: 0, y: 0, width: 20, height: 20), in: crop))
    }

    func testOnlyAnObservationOfTheDirtyAreaResetsTheNextCrop() throws {
        let viewport = CGRect(x: -400, y: -400, width: 1_600, height: 1_600)
        let initial = CGRect(x: 140, y: 160, width: 52, height: 28)
        let change = CGRect(x: 210, y: 160, width: 25, height: 28)
        var edits = TutorDirtyRegion()
        edits.record(initial)
        edits.acknowledge(in: CGRect(x: -350, y: -300, width: 110, height: 110))
        XCTAssertEqual(edits.bounds, initial)

        let sent = try XCTUnwrap(edits.crop(in: viewport))
        edits.acknowledge(in: sent)
        XCTAssertNil(edits.crop(in: viewport))
        edits.record(change)
        XCTAssertEqual(edits.bounds, change)
        XCTAssertEqual(edits.crop(in: viewport)?.width, change.width + 400)
    }

    func testObservationTimingHonorsPencilIdleQuietModeAndRateLimit() throws {
        var timing = TutorObservationTiming()
        XCTAssertNil(timing.delay(at: 110, manual: false, mode: .automatic, usingPencil: false))
        timing.pendingInk = true
        XCTAssertNil(timing.delay(at: 110, manual: false, mode: .manual, usingPencil: false))
        XCTAssertNil(timing.delay(at: 110, manual: true, mode: .disabled, usingPencil: false))
        XCTAssertNil(timing.delay(at: 110, manual: false, mode: .disabled, usingPencil: false))
        XCTAssertNil(timing.delay(at: 110, manual: false, mode: .automatic, usingPencil: true))
        XCTAssertNil(timing.delay(at: 110, manual: true, mode: .manual, usingPencil: true))
        XCTAssertEqual(timing.delay(at: 110, manual: false, mode: .automatic, usingPencil: false), 1.3)
        XCTAssertEqual(timing.delay(at: 110, manual: true, mode: .manual, usingPencil: false), 0)
        timing.lastAttempt = 109
        XCTAssertEqual(timing.delay(at: 110, manual: false, mode: .automatic, usingPencil: false), 7)
        XCTAssertEqual(timing.delay(at: 110, manual: true, mode: .manual, usingPencil: false), 7)
        XCTAssertEqual(timing.delay(at: 119, manual: false, mode: .automatic, usingPencil: false), 1.3)
    }

    func testCurrentModeOverridesOldPreferencesAndFiltersUnpromptedFeedback() {
        let request = UUID()
        XCTAssertEqual(TutorInterventionMode(enabled: false, automatic: true), .disabled)
        XCTAssertEqual(TutorInterventionMode(enabled: true, automatic: false), .manual)
        XCTAssertEqual(TutorInterventionMode(stored: "disabled", enabled: true, automatic: true), .disabled)
        XCTAssertEqual(TutorInterventionMode(stored: "manual", enabled: true, automatic: true), .manual)
        XCTAssertEqual(TutorInterventionMode(stored: "unknown", enabled: true, automatic: true), .disabled)
        XCTAssertFalse(TutorInterventionMode.disabled.presentsFollowUp(request, promptedBy: request))
        XCTAssertFalse(TutorInterventionMode.manual.presentsFollowUp(request, promptedBy: nil))
        XCTAssertFalse(TutorInterventionMode.manual.presentsFollowUp(request, promptedBy: UUID()))
        XCTAssertTrue(TutorInterventionMode.manual.presentsFollowUp(request, promptedBy: request))
        XCTAssertTrue(TutorInterventionMode.automatic.presentsFollowUp(request, promptedBy: nil))
    }

    func testWireContractUsesOnlyTheBoundedImageAndAuthorizedEntities() throws {
        let crop = CGRect(x: 80, y: -100, width: 100, height: 100)
        let entity = try XCTUnwrap(TutorCropEntity(id: UUID(), bounds: crop.insetBy(dx: 10, dy: 20), in: crop))
        let followUp = TutorRecentEvent(revision: 2, kind: .math, transcript: "2+2=4", feedback: "확인했어요.",
                                        isFollowUp: true)
        let capture = TutorCapture(noteID: UUID(), inkRevision: 3, crop: crop, entities: [entity],
                                   png: Data([1, 2, 3]), recent: [followUp], fingerprint: Data([0]))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(capture)) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["observation", "image", "entities", "recent"])
        XCTAssertEqual(body["image"] as? String, "AQID")
        let observation = try XCTUnwrap(body["observation"] as? [String: Any])
        XCTAssertEqual(observation["requestId"] as? String, capture.context.requestID.uuidString)
        XCTAssertEqual(observation["canvasRevision"] as? Int, 3)
        XCTAssertEqual(observation["entityIds"] as? [String], [entity.id.uuidString])
        XCTAssertEqual(capture.context.entityIDs, [entity.id])
        let history = try XCTUnwrap(body["recent"] as? [[String: Any]])
        XCTAssertEqual(history.first?["feedback"] as? String, followUp.feedback)
        XCTAssertNil(history.first?["isFollowUp"])
    }

    func testRawGatewayReplyEnforcesPolicyAndDoesNotDecodeInjectedKeysAway() throws {
        let id = UUID()
        let context = TutorContext(requestID: UUID(), noteID: UUID(), inkRevision: 3, entityIDs: [id])
        let action: [String: Any] = [
            "actionId": UUID().uuidString, "type": "ask_question", "targetEntityId": id.uuidString,
            "placementIntent": "near_right", "content": "다시 계산해 볼래?"
        ]
        var reply: [String: Any] = [
            "schemaVersion": 1, "requestId": context.requestID.uuidString, "noteId": context.noteID.uuidString,
            "observedRevision": context.inkRevision, "decision": "act", "actions": [action]
        ]
        var recognition: [String: Any] = ["kind": "math", "transcript": "2+2=5", "confidence": 0.94,
                                          "targetEntityIds": [id.uuidString]]
        func decode() throws -> TutorGatewayReply {
            try TutorGatewayReply.decode(JSONSerialization.data(withJSONObject: [
                "model": "test-vision", "reason": "Check the sum", "recognition": recognition, "response": reply
            ]), context: context)
        }
        let validated = try decode()
        XCTAssertEqual(validated.proposal?.actions.first?.targetID, id)
        XCTAssertNotNil(validated.applying(.reserved).proposal)
        XCTAssertNil(validated.applying(.cautious).proposal)
        recognition["confidence"] = 0.3
        XCTAssertNil(try decode().proposal)
        recognition["confidence"] = 0.94
        reply["actions"] = [action.merging(["worldX": 1]) { _, new in new }]
        XCTAssertThrowsError(try decode())
        reply["actions"] = [action]
        reply["observedRevision"] = 2
        XCTAssertThrowsError(try decode())
    }

    func testGatewayRequiresHTTPSAndDoesNotAcceptCredentialsInTheURL() throws {
        XCTAssertEqual(try TutorGateway.observationEndpoint("https://tutor.example/app").absoluteString,
                       "https://tutor.example/app/v1/tutor/observe")
        XCTAssertThrowsError(try TutorGateway.observationEndpoint("http://tutor.example"))
        XCTAssertThrowsError(try TutorGateway.observationEndpoint("https://user:secret@tutor.example"))
        XCTAssertThrowsError(try TutorGateway.observationEndpoint("https://tutor.example/?secret=1"))
    }

    func testRepeatedWorkUsesNormalizedNotationAndDistinguishesACorrection() {
        let previous = TutorRecentEvent(revision: 4, kind: .math, transcript: "２ + ２ = ５",
                                        feedback: "다시 계산해 볼래?", offeredHint: true)
        XCTAssertTrue(previous.matchesWork(kind: .math, transcript: "2+2=5"))
        XCTAssertFalse(previous.matchesWork(kind: .math, transcript: "2+2=4"))
        XCTAssertFalse(previous.matchesWork(kind: .text, transcript: "2+2=5"))
    }

    func testFollowUpRequiresAChangedRecognizedAnswerAboveTheConfiguredThreshold() throws {
        let crop = CGRect(x: 100, y: -140, width: 100, height: 200)
        let entity = try XCTUnwrap(TutorCropEntity(id: UUID(), bounds: crop.insetBy(dx: 10, dy: 20), in: crop))
        let previous = TutorRecentEvent(revision: 1, kind: .math, transcript: "2+2=5",
                                        feedback: "다시 계산해 볼래?", offeredHint: true)
        let capture = TutorCapture(noteID: UUID(), inkRevision: 2, crop: crop, entities: [entity],
                                   png: Data([0]), recent: [previous], fingerprint: Data())
        func history(_ transcript: String, kind: TutorSubject = .math, reason: String = "수정한 답을 확인했어요.",
                     sensitivity: TutorSensitivity = .standard) -> TutorRecentEvent? {
            let recognition = TutorRecognition(kind: kind, transcript: transcript, confidence: 0.88,
                                               targetEntityIds: [entity.id])
            return TutorGatewayReply(recognition: recognition, reason: reason, proposal: nil)
                .historyEntry(for: capture, sensitivity: sensitivity)?.event
        }
        XCTAssertEqual(history("2+2=4")?.isFollowUp, true)
        XCTAssertNil(history("２ + ２ = ５")?.isFollowUp)
        XCTAssertNil(history("2+2=4", kind: .text)?.isFollowUp)
        XCTAssertNil(history("2+2=4", reason: "  ")?.isFollowUp)
        XCTAssertNil(history("2+2=4", sensitivity: .reserved)?.isFollowUp)
    }

    func testBackoffRespectsServerLimitsAndDoesNotRetryInvalidCredentials() throws {
        var retry = TutorRetryWindow()
        retry.recordFailure(at: 100, retryAfter: TutorGateway.retryDelay("75"))
        XCTAssertEqual(retry.notBefore, 175)
        retry.recordFailure(at: 175)
        XCTAssertEqual(retry.notBefore, 191)
        retry.recordFailure(at: 191)
        XCTAssertEqual(retry.notBefore, 223)
        retry.recordFailure(at: 223)
        retry.recordFailure(at: 283)
        XCTAssertEqual(retry.notBefore, 343)
        XCTAssertEqual(TutorGateway.retryDelay("999999"), 86_400)
        XCTAssertNil(TutorGateway.retryDelay("invalid"))
        XCTAssertNil(TutorGateway.retryDelay("-2"))
        retry.requireNewCredentials()
        XCTAssertEqual(retry.notBefore, .infinity)
        XCTAssertEqual(TutorRetryWindow().notBefore, 0)
    }
}

#if os(Linux)
@main
private enum TutorCaptureTestRunner {
    static func main() {
        XCTMain([testCase([
            ("testNearbyEditsMergeAndDistantEditsStayLocal", TutorCaptureTests.testNearbyEditsMergeAndDistantEditsStayLocal),
            ("testCropUsesOnlyOnScreenIntersectionAndNormalizesVisibleStroke", TutorCaptureTests.testCropUsesOnlyOnScreenIntersectionAndNormalizesVisibleStroke),
            ("testOnlyAnObservationOfTheDirtyAreaResetsTheNextCrop", TutorCaptureTests.testOnlyAnObservationOfTheDirtyAreaResetsTheNextCrop),
            ("testObservationTimingHonorsPencilIdleQuietModeAndRateLimit", TutorCaptureTests.testObservationTimingHonorsPencilIdleQuietModeAndRateLimit),
            ("testCurrentModeOverridesOldPreferencesAndFiltersUnpromptedFeedback", TutorCaptureTests.testCurrentModeOverridesOldPreferencesAndFiltersUnpromptedFeedback),
            ("testWireContractUsesOnlyTheBoundedImageAndAuthorizedEntities", TutorCaptureTests.testWireContractUsesOnlyTheBoundedImageAndAuthorizedEntities),
            ("testRawGatewayReplyEnforcesPolicyAndDoesNotDecodeInjectedKeysAway", TutorCaptureTests.testRawGatewayReplyEnforcesPolicyAndDoesNotDecodeInjectedKeysAway),
            ("testGatewayRequiresHTTPSAndDoesNotAcceptCredentialsInTheURL", TutorCaptureTests.testGatewayRequiresHTTPSAndDoesNotAcceptCredentialsInTheURL),
            ("testRepeatedWorkUsesNormalizedNotationAndDistinguishesACorrection", TutorCaptureTests.testRepeatedWorkUsesNormalizedNotationAndDistinguishesACorrection),
            ("testFollowUpRequiresAChangedRecognizedAnswerAboveTheConfiguredThreshold", TutorCaptureTests.testFollowUpRequiresAChangedRecognizedAnswerAboveTheConfiguredThreshold),
            ("testBackoffRespectsServerLimitsAndDoesNotRetryInvalidCredentials", TutorCaptureTests.testBackoffRespectsServerLimitsAndDoesNotRetryInvalidCredentials)
        ])])
    }
}
#endif
