import CoreImage
import PencilKit
import UIKit
import XCTest
@testable import ReedlesCanvas

final class TutorLiveGatewayTests: XCTestCase {
    private struct Configuration: Decodable {
        let baseURL: String
        let accessToken: String
    }

    @MainActor
    func testRealPencilKitEquationHintCorrectionFollowUpAndRestoration() async throws {
        guard let resource = Bundle(for: Self.self).url(forResource: "LiveGateway", withExtension: "json") else {
            #if REEDLE_LIVE_GATEWAY_REQUIRED
            XCTFail("The required live BAZE test resource is missing from the test bundle")
            return
            #else
            throw XCTSkip("Live BAZE relay is not configured for this run")
            #endif
        }
        let config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: resource))
        let endpoint = try TutorGateway.observationEndpoint(config.baseURL)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let noteURL = directory.appendingPathComponent("drawing.pkdrawing")
        let template = try TutorExample.open()
        try XCTUnwrap(template.store).export(to: noteURL.deletingPathExtension().appendingPathExtension("sqlite"))
        let document = DrawingDocument(fileURL: noteURL)
        let canvas = PagedCanvasView()
        document.attach(canvas)
        let viewport = CGRect(x: 0, y: 0, width: 760, height: 600)
        XCTAssertTrue(document.updateViewport(viewport, surfaceOrigin: .zero))
        let store = try XCTUnwrap(document.store)
        let original = try store.strokes(in: viewport)
        XCTAssertEqual(original.count, 7)
        let first = try XCTUnwrap(document.captureForTutor(manual: true))
        attach(first.png, named: "Actual PencilKit 2+2=5 input")
        var firstPhases: [TutorStreamPhase] = []
        let firstReply = try await TutorGateway.observe(first, endpoint: endpoint, accessToken: config.accessToken) {
            firstPhases.append($0)
        }
        XCTAssertEqual(firstPhases, [.reading, .drafting])
        XCTAssertEqual(firstReply.recognition.kind, .math)
        XCTAssertTrue(firstReply.recognition.transcript.replacingOccurrences(of: " ", with: "").contains("2+2=5"))
        let proposal = try XCTUnwrap(firstReply.proposal)
        XCTAssertTrue(proposal.actions.contains { $0.kind == .draw && $0.content == "circle"
            && $0.targetID == TutorExample.answerID })
        XCTAssertTrue(proposal.actions.contains { $0.kind == .askQuestion && $0.targetID == TutorExample.answerID })
        try document.finishTutorObservation(first, reply: firstReply)
        try document.approveTutorProposal(proposal)
        XCTAssertEqual(try store.strokes(in: viewport), original)
        XCTAssertEqual(document.tutorAnnotations.count, proposal.actions.count)
        attach(try NoteResourceExport.image(from: document).data, named: "Actual BAZE approved hint")
        let marked = DrawingDocument(fileURL: noteURL)
        XCTAssertTrue(marked.updateViewport(viewport, surfaceOrigin: .zero))
        XCTAssertEqual(try XCTUnwrap(marked.store).strokes(in: viewport), original)
        XCTAssertEqual(marked.tutorAnnotations, document.tutorAnnotations)

        // Replace only the student's final digit through the actual native edit path.
        let withoutFive = zip(original, canvas.drawing.strokes).filter { $0.0.id != TutorExample.answerID }
            .map { $0.1 }
        let four = [CGPoint(x: 284, y: 129), CGPoint(x: 267, y: 151), CGPoint(x: 296, y: 151),
                    CGPoint(x: 286, y: 151), CGPoint(x: 286, y: 128), CGPoint(x: 286, y: 166)]
        let points = four.enumerated().map { index, point in
            PKStrokePoint(location: point, timeOffset: Double(index)/60, size: CGSize(width: 3.2, height: 3.2),
                          opacity: 1, force: 0.7, azimuth: 0.4, altitude: 1.2)
        }
        document.beginToolInteraction()
        canvas.drawing = PKDrawing(strokes: withoutFive + [PKStroke(ink: PKInk(.pen, color: .black),
            path: PKStrokePath(controlPoints: points, creationDate: Date()))])
        document.drawingDidChange(canvas)
        document.endToolInteraction()
        try document.flushPendingEdits()
        let corrected = try store.strokes(in: viewport)
        XCTAssertEqual(corrected.count, 7)
        XCTAssertFalse(corrected.contains { $0.id == TutorExample.answerID })
        // A student edit can re-encode PencilKit's archive. Check the unchanged
        // ink in world coordinates; approval above still requires exact records.
        try assertSameInk(Array(original.prefix(6)), Array(corrected.prefix(6)))
        let second = try XCTUnwrap(document.captureForTutor(manual: true))
        XCTAssertGreaterThan(second.context.inkRevision, first.context.inkRevision)
        XCTAssertTrue(second.recent.contains { $0.offeredHint == true })
        attach(second.png, named: "Actual PencilKit 2+2=4 correction")
        var secondPhases: [TutorStreamPhase] = []
        let followUp = try await TutorGateway.observe(second, endpoint: endpoint, accessToken: config.accessToken) {
            secondPhases.append($0)
        }
        XCTAssertEqual(secondPhases, [.reading, .drafting])
        XCTAssertEqual(followUp.recognition.kind, .math)
        XCTAssertTrue(followUp.recognition.transcript.replacingOccurrences(of: " ", with: "").contains("2+2=4"))
        XCTAssertNil(followUp.proposal)
        try document.finishTutorObservation(second, reply: followUp)
        XCTAssertNotNil(document.tutorFollowUp)
        XCTAssertFalse(try XCTUnwrap(document.tutorFollowUp).text.isEmpty)
        XCTAssertEqual(try store.strokes(in: viewport), corrected)
        let reopened = DrawingDocument(fileURL: noteURL)
        XCTAssertTrue(reopened.updateViewport(viewport, surfaceOrigin: .zero))
        XCTAssertEqual(try XCTUnwrap(reopened.store).strokes(in: viewport), corrected)
        XCTAssertEqual(reopened.tutorFollowUp, document.tutorFollowUp)
        XCTAssertEqual(try reopened.tutorHistoryForReading().count, 2)
        attach(try NoteResourceExport.image(from: reopened).data, named: "Restored corrected student ink")
        let proof: [String: Any] = [
            "firstTranscript": firstReply.recognition.transcript,
            "firstConfidence": firstReply.recognition.confidence,
            "hint": proposal.actions.map { ["type": String(describing: $0.kind), "content": $0.content,
                                           "targetID": $0.targetID.uuidString] },
            "correctedTranscript": followUp.recognition.transcript,
            "correctedConfidence": followUp.recognition.confidence,
            "followUp": followUp.reason,
            "studentStrokesAfterReopen": reopened.strokeCount
        ]
        let evidence = XCTAttachment(data: try JSONSerialization.data(withJSONObject: proof, options: [.prettyPrinted]),
                                     uniformTypeIdentifier: "public.json")
        evidence.name = "Actual BAZE native round trip"
        evidence.lifetime = .keepAlways
        add(evidence)
    }

    private func attach(_ png: Data, named name: String) {
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func assertSameInk(_ expected: [StoredStroke], _ actual: [StoredStroke],
                               file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(actual.map(\.id), expected.map(\.id), file: file, line: line)
        for (before, after) in zip(expected, actual) {
            XCTAssertEqual(after.bounds, before.bounds, file: file, line: line)
            XCTAssertEqual(after.zIndex, before.zIndex, file: file, line: line)
            let original = try XCTUnwrap(PKDrawing(data: before.data).strokes.first)
            let restored = try XCTUnwrap(PKDrawing(data: after.data).strokes.first)
            XCTAssertEqual(restored.ink.inkType, original.ink.inkType, file: file, line: line)
            let a = CIColor(color: original.ink.color), b = CIColor(color: restored.ink.color)
            for (x, y) in zip([a.red, a.green, a.blue, a.alpha], [b.red, b.green, b.blue, b.alpha]) {
                XCTAssertEqual(x, y, accuracy: 0.01, file: file, line: line)
            }
            XCTAssertEqual(restored.randomSeed, original.randomSeed, file: file, line: line)
            XCTAssertEqual(restored.maskedPathRanges, original.maskedPathRanges, file: file, line: line)
            XCTAssertEqual(restored.path.creationDate.timeIntervalSince(original.path.creationDate), 0,
                           accuracy: 0.001, file: file, line: line)
            XCTAssertEqual(restored.path.count, original.path.count, file: file, line: line)
            for (x, y) in zip([original.transform.a, original.transform.b, original.transform.c, original.transform.d],
                              [restored.transform.a, restored.transform.b, restored.transform.c, restored.transform.d]) {
                XCTAssertEqual(x, y, accuracy: 0.000001, file: file, line: line)
            }
            for (p, q) in zip(original.path, restored.path) {
                let x = p.location.applying(original.transform)
                let y = q.location.applying(restored.transform)
                XCTAssertEqual(x.x + before.bounds.minX - original.renderBounds.minX,
                               y.x + after.bounds.minX - restored.renderBounds.minX, accuracy: 0.01, file: file, line: line)
                XCTAssertEqual(x.y + before.bounds.minY - original.renderBounds.minY,
                               y.y + after.bounds.minY - restored.renderBounds.minY, accuracy: 0.01, file: file, line: line)
                for (u, v) in zip([p.size.width, p.size.height, p.force, p.opacity, p.azimuth, p.altitude],
                                  [q.size.width, q.size.height, q.force, q.opacity, q.azimuth, q.altitude]) {
                    XCTAssertEqual(u, v, accuracy: 0.01, file: file, line: line)
                }
                XCTAssertEqual(p.timeOffset, q.timeOffset, accuracy: 0.001, file: file, line: line)
            }
        }
    }
}
