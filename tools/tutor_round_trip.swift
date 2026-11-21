import Foundation

@main
enum TutorRoundTrip {
    private struct FailedCheck: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    private static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw FailedCheck(message) }
    }

    static func main() async {
        do { try await verify() }
        catch {
            FileHandle.standardError.write(Data("Tutor round trip failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    @MainActor
    private static func verify() async throws {
        let endpoint = URL(string: CommandLine.arguments[1])!
        let folder = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let offline = URL(string: CommandLine.arguments[3])!
        let noteURL = folder.appendingPathComponent("observation.sqlite")
        let store = try NoteStore(url: noteURL)
        let area = CGRect(x: -20, y: 80, width: 240, height: 150)
        let target = CGRect(x: 120, y: 100, width: 12, height: 24)
        let wrong = StoredStroke(id: UUID(uuidString: "10000000-0000-4000-8000-000000000005")!,
                                 bounds: target, zIndex: 0, data: Data([5]))
        let corrected = StoredStroke(id: UUID(uuidString: "10000000-0000-4000-8000-000000000004")!,
                                     bounds: target, zIndex: 1, data: Data([4]))
        func capture(_ stem: String, _ stroke: StoredStroke) throws -> TutorCapture {
            let metadata = try store.metadata()
            let png = try Data(contentsOf: folder.appendingPathComponent(stem + ".png"))
            let entity = TutorCropEntity(id: stroke.id, bounds: stroke.bounds, in: area)!
            return TutorCapture(noteID: metadata.noteID, inkRevision: metadata.inkRevision, crop: area,
                                entities: [entity], png: png,
                                recent: try store.tutorHistory(near: area, before: metadata.inkRevision),
                                fingerprint: png)
        }

        try store.commit(upserts: [wrong])
        let firstCapture = try capture("wrong", wrong)
        let first = try await TutorGateway.observe(firstCapture, endpoint: endpoint, accessToken: "local-test-access") { phase in
            let marker = folder.appendingPathComponent("client-\(phase.rawValue)")
            _ = FileManager.default.createFile(atPath: marker.path, contents: nil)
        }
        try await waitForMarker("client-reading", in: folder)
        try await waitForMarker("client-drafting", in: folder)
        guard let hint = first.proposal, let anchor = first.proposalAnchor(in: firstCapture),
              let firstEntry = first.historyEntry(for: firstCapture, sensitivity: .standard) else {
            throw FailedCheck("No grounded hint for the incorrect expression.")
        }
        let camera = CanvasCamera(origin: area.origin, scale: 1)
        let screen = CGRect(origin: .zero, size: area.size)
        guard let preview = TutorPlacement.notice(size: CGSize(width: 156, height: 44), beside: anchor,
                                                   camera: camera, obstacles: [target], viewport: screen) else {
            throw FailedCheck("The draft could not be reviewed beside the selected ink.")
        }
        try check(screen.contains(preview) && !preview.intersects(camera.screenRect(for: target)),
                  "The preview covered student ink or left the viewport.")
        try check(first.recognition.transcript == "2+2=5", "Incorrect expression failed to round-trip.")
        try check(hint.actions.map(\.ink) == [.drawing(.circle), .text("다시 계산해 볼래?")],
                  "The hint did not include the circle and the question.")
        try store.recordTutorEvent(firstEntry.event, crop: firstEntry.bounds, for: firstCapture.context)
        try check(try store.tutorAnnotations(anchoredIn: area).isEmpty, "Unapproved annotation was saved.")
        try check(try store.applyTutorProposal(hint), "Tutor hint failed to save.")
        try check(try store.strokes(in: area) == [wrong], "Approving a hint changed student ink.")
        let restoredHint = try NoteStore(url: noteURL).tutorAnnotations(anchoredIn: area)
        let marks = TutorMark.layout(restoredHint, anchors: [wrong.id: target], in: area) { _ in
            CGSize(width: 108, height: 40)
        }
        try check(marks.map(\.id) == hint.actions.map(\.id), "The approved circle and question were lost on reopen.")
        try store.commit(aiLayerVisible: false)
        try check(try !NoteStore(url: noteURL).metadata().aiLayerVisible, "Hiding the tutor layer did not survive reopen.")
        try check(try store.strokes(in: area) == [wrong], "Hiding the tutor layer changed student ink.")
        try store.commit(aiLayerVisible: true)

        let replay = try await TutorGateway.observe(firstCapture, endpoint: endpoint, accessToken: "local-test-access")
        try check(replay.proposal?.actions.map(\.id) == hint.actions.map(\.id), "Retry changed action identifiers.")

        try store.commit(upserts: [wrong])
        let repeated = try capture("wrong", wrong)
        let repeatReply = try await TutorGateway.observe(repeated, endpoint: endpoint, accessToken: "local-test-access")
        try check(repeatReply.proposal == nil && repeatReply.recognition.transcript == "2+2=5",
                  "Rewriting the same expression produced another hint.")
        guard let repeatEntry = repeatReply.historyEntry(for: repeated, sensitivity: .standard) else {
            throw FailedCheck("The repeated observation did not retain its context.")
        }
        try check(repeatEntry.event.offeredHint == true && repeatEntry.event.isFollowUp == nil,
                  "Unchanged work was presented as a correction.")
        try store.recordTutorEvent(repeatEntry.event, crop: repeatEntry.bounds, for: repeated.context)

        try store.commit(upserts: [corrected], deleting: [wrong.id])
        let secondCapture = try capture("corrected", corrected)
        try check(secondCapture.recent.last?.transcript == "2+2=5", "Past recognition was not carried into the next edit.")
        let second = try await TutorGateway.observe(secondCapture, endpoint: endpoint, accessToken: "local-test-access")
        try check(second.recognition.transcript == "2+2=4", "Corrected expression failed to round-trip.")
        try check(second.proposal == nil && second.reason == "수정한 계산이 맞아요.",
                  "A correct expression should receive acknowledgment without a new annotation.")
        guard let secondEntry = second.historyEntry(for: secondCapture, sensitivity: .standard) else {
            throw FailedCheck("The follow-up had no grounded location.")
        }
        try check(secondEntry.event.isFollowUp == true, "The corrected expression did not produce canvas feedback.")
        try store.recordTutorEvent(secondEntry.event, crop: secondEntry.bounds, for: secondCapture.context)
        let reopened = try NoteStore(url: noteURL)
        try check(try reopened.strokes(in: area) == [corrected], "Reopening changed the corrected student ink.")
        try check(try reopened.tutorAnnotations(anchoredIn: area).isEmpty, "The old hint reappeared after correction.")
        try check(try reopened.currentTutorFollowUp() == TutorFollowUp(requestID: secondCapture.context.requestID,
                                                                     text: second.reason, anchor: secondEntry.bounds),
                  "Reopening lost the follow-up or its anchor.")
        guard let feedback = TutorPlacement.notice(size: CGSize(width: 230, height: 84), beside: secondEntry.bounds,
                                                    camera: camera, obstacles: [corrected.bounds], viewport: screen) else {
            throw FailedCheck("The correction feedback could not be placed by the answer.")
        }
        try check(screen.contains(feedback) && !feedback.intersects(camera.screenRect(for: corrected.bounds)),
                  "The correction feedback covered the answer or left the viewport.")
        print("Swift ↔ FastAPI: suggestion placement, protected approval, concealment, correction and SQLite reopen passed")

        let studyArea = area.insetBy(dx: -260, dy: -150)
        let practice = try reopened.startPractice(for: nil, in: studyArea, avoiding: [])
        guard let problem = practice.current else { throw FailedCheck("The corrected work did not start practice.") }
        try check(problem.problem.skill == .addition && problem.problem.prompt != "2 + 2",
                  "Practice did not build a new exercise about the corrected work.")
        try check(studyArea.contains(problem.frame) && !problem.frame.intersects(corrected.bounds),
                  "Practice covered the corrected answer or left the visible canvas.")
        let solution = try reopened.updatePractice { journal in
            try check(journal.revealHint(), "Could not open the first hint.")
            try check(journal.submit(String(problem.problem.answer + 1)) == .retry, "A wrong practice answer was accepted.")
            return journal.submit(String(problem.problem.answer))
        }
        try check(solution.value == .correct, "The correct practice answer was rejected.")
        let savedPractice = try store.practiceJournal()
        try check(savedPractice.current?.solved == true && savedPractice.statistics[.addition]?.assistedSolutions == 1,
                  "Practice and its learning record did not survive a second connection.")
        print("Swift ↔ FastAPI: corrected work seeded an offline exercise that was placed, graded and restored")

        let noteAddition = StoredStroke(id: UUID(), bounds: target.offsetBy(dx: -40, dy: 18),
                                        zIndex: 2, data: Data([1, 2, 3]))
        let slowCapture = try capture("slow", corrected)
        let request = TutorRequestTask()
        var launched = false
        let queued = request.start { _ in launched = true }
        request.cancel()
        await queued.value
        try check(!launched, "Stopping the tutor allowed queued work to start.")
        var stopped = false
        var failure: Error?
        let inFlight = request.start { _ in
            do {
                _ = try await TutorGateway.observe(slowCapture, endpoint: endpoint, accessToken: "local-test-access") { phase in
                    if phase == .drafting {
                        let marker = folder.appendingPathComponent("slow-drafting")
                        _ = FileManager.default.createFile(atPath: marker.path, contents: nil)
                    }
                }
            } catch is CancellationError {
                stopped = true
            } catch let error as URLError where error.code == .cancelled {
                stopped = true
            } catch {
                failure = error
            }
        }
        defer { request.cancel() }
        try await waitForMarker("upstream-started", in: folder)
        try await waitForMarker("slow-drafting", in: folder)
        try store.commit(upserts: [noteAddition])
        try check(try reopened.currentTutorFollowUp() == nil, "Old feedback remained visible after a new edit.")
        request.cancel()
        await inFlight.value
        if let failure { throw failure }
        try check(stopped && request.id == nil, "The stopped request returned an applicable reply.")
        try check(!TutorInterventionMode.manual.permitsRequest(manual: false, pendingInk: true),
                  "Quiet mode allowed a new automatic request.")
        try check(!TutorInterventionMode.disabled.permitsRequest(manual: true, pendingInk: true),
                  "The disabled tutor still allowed a new request.")
        try await waitForMarker("upstream-cancelled", in: folder)

        let failedCapture = try capture("failing", corrected)
        do {
            _ = try await TutorGateway.observe(failedCapture, endpoint: endpoint, accessToken: "local-test-access") { _ in }
            throw FailedCheck("Provider 5xx was accepted.")
        } catch TutorGatewayError.unavailable {
        }
        do {
            _ = try await TutorGateway.observe(try capture("corrected", corrected), endpoint: endpoint,
                                              accessToken: "local-test-access") { _ in }
            throw FailedCheck("A request exceeded the daily budget.")
        } catch TutorGatewayError.limit(let retryAfter) {
            try check((retryAfter ?? 0) > 0, "Retry-After was lost on a rate-limited response.")
        }
        do {
            _ = try await TutorGateway.observe(try capture("corrected", corrected), endpoint: offline,
                                              accessToken: "local-test-access")
            throw FailedCheck("The offline destination returned a reply.")
        } catch let error as URLError where error.code == .cannotConnectToHost || error.code == .notConnectedToInternet {
        }
        try check(try reopened.strokes(in: area) == [corrected, noteAddition], "Network trouble changed saved ink.")
        try check(try reopened.tutorAnnotations(anchoredIn: area).isEmpty,
                  "A cancelled or failed observation produced a persisted annotation.")
        print("Swift ↔ FastAPI: tutor stop cancelled a live request while SQLite ink edits continued; offline and 429/5xx passed")
    }

    private static func waitForMarker(_ name: String, in folder: URL) async throws {
        let marker = folder.appendingPathComponent(name)
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: marker.path) { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw FailedCheck("No test marker for \(name).")
    }
}
