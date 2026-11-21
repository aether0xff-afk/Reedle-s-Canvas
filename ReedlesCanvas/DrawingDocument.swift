import Combine
import CryptoKit
import Foundation
import os
import PencilKit
import UIKit

/// World-history actions are the same for the toolbar, PencilKit picker and system shortcuts.
class PagedCanvasView: PKCanvasView {
    weak var documentHistory: UndoManager?
    override var undoManager: UndoManager? { documentHistory }
}

private struct VisibleStroke {
    let record: StoredStroke
    let local: PKStroke
}

private struct StrokeChange {
    let before: StoredStroke?
    let after: StoredStroke?
}

private enum DrawingStorageError: Error {
    case invalidStroke, unavailable
}

@MainActor
final class DrawingDocument: ObservableObject {
    private static let pageLog = OSLog(subsystem: "dev.aether.reedlescanvas", category: "Canvas paging")
    @Published private(set) var strokeCount = 0
    @Published private(set) var loadedStrokeCount = 0
    @Published private(set) var aiLayerVisible = true
    @Published private(set) var tutorAnnotations: [TutorAnnotation] = []
    @Published private(set) var tutorMarks: [TutorMark] = []
    @Published private(set) var tutorFollowUp: TutorFollowUp?
    @Published private(set) var canUndoTutor = false
    @Published private(set) var latestTutorRequest: UUID?
    @Published private(set) var inkActivity: UInt64 = 0
    @Published private(set) var practice = PracticeJournal()
    @Published private(set) var loadError: String?
    @Published var showSaveError = false
    @Published private(set) var saveError: String?

    private(set) var restoredCamera: CanvasCamera?
    private(set) var drawing = PKDrawing()
    private(set) var toolActive = false
    private let history = UndoManager()
    private(set) var store: NoteStore?
    private weak var canvas: PKCanvasView?
    private var visible: [VisibleStroke] = []
    private var ledger = StrokeIdentityLedger()
    private var loadedWorldRect: CGRect?
    private var viewport: CGRect?
    private var tutorDirtyRegion = TutorDirtyRegion()
    private var surfaceOrigin: CGPoint = .zero
    private var nextZ: Int64 = 0
    private var applyingPage = false

    // Pending edits are retained through write failures and merged into spatial query results.
    private var pendingUpserts: [UUID: StoredStroke] = [:]
    private var pendingDeletions: Set<UUID> = []
    private var pendingOrder: [UUID: Int64] = [:]
    private var cameraDirty = false
    private var visibilityDirty = false
    private var scheduledSave: DispatchWorkItem?
    private var saveRetry = NoteSaveRetry()

    var canUndo: Bool { history.canUndo }
    var canRedo: Bool { history.canRedo }
    var currentWorldViewport: CGRect? { viewport }

    convenience init() {
        var directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #if DEBUG && (targetEnvironment(simulator) || REEDLE_UI_TEST_SUPPORT)
        if let value = ProcessInfo.processInfo.environment["REEDLE_UI_TEST_NOTE_ID"], let id = UUID(uuidString: value) {
            directory = directory.appendingPathComponent("UITest-\(id.uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        #endif
        self.init(fileURL: directory.appendingPathComponent("drawing.pkdrawing"))
    }

    init(fileURL: URL) {
        history.groupsByEvent = false
        history.levelsOfUndo = 30
        // PencilKit's native undo entries contain viewport-local coordinates. Register only the
        // world-space edits below so undo cannot replay stale coordinates after a page switch.
        history.disableUndoRegistration()
        do {
            let database = try NoteStore(url: fileURL.deletingPathExtension().appendingPathExtension("sqlite"),
                                         busyTimeoutMilliseconds: 16)
            var metadata = try database.metadata()
            if metadata.revision == 0 && metadata.strokeCount == 0 {
                try Self.importLegacyInk(at: fileURL, into: database)
                metadata = try database.metadata()
            }
            store = database
            strokeCount = metadata.strokeCount
            nextZ = metadata.nextZIndex
            restoredCamera = metadata.camera
            aiLayerVisible = metadata.aiLayerVisible
            canUndoTutor = (try? database.hasActiveTutorBatch()) == true
            tutorFollowUp = try? database.currentTutorFollowUp()
            practice = (try? database.practiceJournal()) ?? PracticeJournal()
        } catch {
            loadError = "노트를 열 수 없습니다. 원본 파일을 보존했습니다."
        }
    }

    private static func importLegacyInk(at url: URL, into store: NoteStore) throws {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return }
        let legacy = try PKDrawing(data: data)
        let migrated = try LegacyStrokeCatalog.strokes(in: legacy, archive: data, at: url).enumerated().map { index, stroke in
            try record(for: stroke.source, id: stroke.id, z: Int64(index), surfaceOrigin: .zero)
        }
        try store.commit(upserts: migrated)
    }

    func attach(_ canvas: PKCanvasView) {
        self.canvas = canvas
        (canvas as? PagedCanvasView)?.documentHistory = history
        canvas.drawing = drawing
    }

    func detach(_ canvas: PKCanvasView) {
        guard canvas === self.canvas else { return }
        toolActive = false
        saveNow()
        (canvas as? PagedCanvasView)?.documentHistory = nil
        self.canvas = nil
    }

    func beginToolInteraction() { toolActive = true }

    func endToolInteraction() {
        toolActive = false
        if let canvas { drawingDidChange(canvas) }
    }

    func updateCamera(_ camera: CanvasCamera) {
        guard loadError == nil, camera != restoredCamera else { return }
        restoredCamera = camera
        cameraDirty = true
        scheduleSave()
    }

    func setAILayerVisible(_ visible: Bool) {
        guard loadError == nil, visible != aiLayerVisible else { return }
        aiLayerVisible = visible
        visibilityDirty = true
        scheduleSave()
    }

    func makeTutorContext(around entityIDs: Set<UUID>) throws -> TutorContext {
        guard let store, !toolActive, loadError == nil else { throw DrawingStorageError.unavailable }
        if let canvas { try capture(canvas) }
        try commit()
        guard !entityIDs.isEmpty, entityIDs.isSubset(of: Set(visible.map { $0.record.id })) else {
            throw TutorProposalError.missingAnchor
        }
        let metadata = try store.metadata()
        return TutorContext(requestID: UUID(), noteID: metadata.noteID, inkRevision: metadata.inkRevision,
                            entityIDs: entityIDs, policyEpoch: metadata.tutorEpoch)
    }

    func captureForTutor(manual: Bool) throws -> TutorCapture? {
        guard let store, let viewport, !toolActive, loadError == nil else { return nil }
        if let canvas { try capture(canvas) }
        try commit()
        var region = tutorDirtyRegion
        if manual, region.crop(in: viewport) == nil,
           let recent = visible.last(where: { $0.record.bounds.intersects(viewport) }) {
            region.record(recent.record.bounds)
        }
        guard let crop = region.crop(in: viewport) else { return nil }
        let metadata = try store.metadata()
        let candidates = try store.strokes(in: crop, newest: TutorCapture.maximumEntities)
        var entities: [TutorCropEntity] = []
        var strokes: [PKStroke] = []
        for candidate in candidates {
            guard let entity = TutorCropEntity(id: candidate.id, bounds: candidate.bounds, in: crop) else { continue }
            let decoded = try Self.decode(candidate, origin: crop.origin)
            entities.append(entity)
            strokes.append(decoded.local)
        }
        guard !strokes.isEmpty else { return nil }
        let png = try Self.tutorImage(PKDrawing(strokes: strokes), in: crop, from: store)
        var hasher = SHA256()
        hasher.update(data: png)
        hasher.update(data: Data("\(crop.origin)-\(entities.map(\.id))".utf8))
        let focus = region.bounds?.intersection(crop).insetBy(dx: -52, dy: -52).intersection(crop) ?? crop
        let recent = try store.tutorHistory(near: focus, before: metadata.inkRevision)
        return TutorCapture(noteID: metadata.noteID, inkRevision: metadata.inkRevision, crop: crop,
                            entities: entities, png: png, recent: recent, fingerprint: Data(hasher.finalize()),
                            policyEpoch: metadata.tutorEpoch)
    }

    private static func tutorImage(_ drawing: PKDrawing, in crop: CGRect, from store: NoteStore) throws -> Data {
        let size = crop.size
        let scale = min(2, 1_280 / max(size.width, size.height))
        let area = CGRect(origin: .zero, size: size)
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = 1
        for resolution in [scale, scale * 0.7, scale * 0.45] {
            let ink = drawing.image(from: area, scale: resolution)
            let imageSize = CGSize(width: min(1_280, max(1, ceil(size.width * resolution))),
                                   height: min(1_280, max(1, ceil(size.height * resolution))))
            let bounds = CGRect(origin: .zero, size: imageSize)
            var failure: Error?
            let image = UIGraphicsImageRenderer(size: imageSize, format: format).image { renderer in
                UIColor.white.setFill()
                renderer.fill(bounds)
                do {
                    let context = renderer.cgContext
                    context.saveGState()
                    context.scaleBy(x: imageSize.width / size.width, y: imageSize.height / size.height)
                    defer { context.restoreGState() }
                    try NotePDFSource.drawMaterials(in: crop, from: store, context: context)
                } catch {
                    failure = error
                }
                ink.draw(in: bounds)
            }
            if let failure { throw failure }
            if let png = image.pngData(), png.count <= TutorCapture.maximumImageBytes { return png }
        }
        throw TutorGatewayError.invalidResult
    }

    func finishTutorObservation(_ capture: TutorCapture, reply: TutorGatewayReply? = nil,
                                sensitivity: TutorSensitivity = .standard) throws {
        guard let store, !toolActive, loadError == nil else { throw TutorProposalError.stale }
        if let canvas { try self.capture(canvas) }
        try commit()
        let metadata = try store.metadata()
        guard metadata.noteID == capture.context.noteID,
              metadata.inkRevision == capture.context.inkRevision,
              metadata.tutorEpoch == capture.context.policyEpoch else { throw TutorProposalError.stale }
        if let entry = reply?.historyEntry(for: capture, sensitivity: sensitivity) {
            try store.recordTutorEvent(entry.event, crop: entry.bounds, for: capture.context)
            tutorFollowUp = try? store.currentTutorFollowUp()
        }
        tutorDirtyRegion.acknowledge(in: capture.crop)
    }

    func approveTutorProposal(_ proposal: TutorProposal) throws {
        guard let store, !toolActive, loadError == nil else { throw DrawingStorageError.unavailable }
        if let canvas { try capture(canvas) }
        try commit()
        if try store.applyTutorProposal(proposal) {
            canUndoTutor = true
            latestTutorRequest = proposal.id
            refreshTutorMarks()
        }
    }

    func undoTutor() throws {
        guard let store, !toolActive, loadError == nil else { throw DrawingStorageError.unavailable }
        if try store.undoLatestTutorBatch() {
            canUndoTutor = try store.hasActiveTutorBatch()
            latestTutorRequest = nil
            refreshTutorMarks()
        }
    }

    private func refreshTutorMarks() {
        let annotations: [TutorAnnotation]
        let marks: [TutorMark]
        if canUndoTutor, let loadedWorldRect, let store {
            annotations = (try? store.tutorAnnotations(anchoredIn: loadedWorldRect)) ?? []
            let anchors = Dictionary(uniqueKeysWithValues: visible.map { ($0.record.id, $0.record.bounds) })
            marks = TutorMark.layout(annotations, anchors: anchors, in: loadedWorldRect,
                                    sizeOfLabel: TutorInkCanvas.labelSize)
        } else {
            annotations = []
            marks = []
        }
        if tutorAnnotations != annotations { tutorAnnotations = annotations }
        if tutorMarks != marks { tutorMarks = marks }
    }

    func relayoutTutor() { refreshTutorMarks() }

    var tutorNoticeObstacles: [CGRect] {
        var obstacles = visible.map { $0.record.bounds } + tutorMarks.map(\.frame)
        if let frame = practice.current?.frame { obstacles.append(frame) }
        return obstacles
    }

    func tutorHistoryForReading() throws -> [TutorRecentEvent] {
        guard let store else { throw DrawingStorageError.unavailable }
        return try store.allRecentTutorEvents()
    }

    func resetTutorFocus() { tutorDirtyRegion = TutorDirtyRegion() }

    func eraseTutorData() throws {
        try flushPendingEdits()
        guard let store else { throw DrawingStorageError.unavailable }
        try store.eraseTutorData()
        resetTutorFocus()
        tutorFollowUp = nil
        canUndoTutor = false
        latestTutorRequest = nil
        refreshTutorMarks()
    }

    @discardableResult
    func updateViewport(_ viewport: CGRect, surfaceOrigin newOrigin: CGPoint) -> Bool {
        guard loadError == nil, !viewport.isEmpty, !toolActive else { return false }
        if surfaceOrigin == newOrigin, loadedWorldRect?.contains(viewport) == true {
            self.viewport = viewport
            return true
        }
        let expanded = viewport.insetBy(dx: -viewport.width / 2, dy: -viewport.height / 2)
        do {
            if let canvas { try capture(canvas) }
            try displayPage(expanded, origin: newOrigin)
            self.viewport = viewport
            return true
        } catch {
            reportFailure()
            return false
        }
    }

    /// Projects the currently resident strokes into world coordinates on demand.
    func worldStrokes() -> [WorldStroke] {
        visible.map { WorldStroke(id: $0.record.id, source: $0.local, worldOrigin: surfaceOrigin) }
    }

    func drawingDidChange(_ canvas: PKCanvasView) {
        guard canvas === self.canvas, !applyingPage, !toolActive, loadError == nil else { return }
        do { try capture(canvas) }
        catch { reportFailure() }
    }

    private func capture(_ canvas: PKCanvasView) throws {
        let current = canvas.drawing
        guard current != drawing else { return }
        let strokes = current.strokes
        var newLedger = ledger
        let ids = newLedger.reconcile(strokes.map(StrokeDescriptor.init))
        let old = Dictionary(uniqueKeysWithValues: visible.map { ($0.record.id, $0) })
        var newPage: [VisibleStroke] = []
        var changes: [StrokeChange] = []
        let retained = Set(ids)
        for previous in visible where !retained.contains(previous.record.id) {
            changes.append(StrokeChange(before: previous.record, after: nil))
        }
        let order = try StrokeOrder(edited: ids, oldVisible: old.mapValues { $0.record.zIndex },
                                    nextZ: nextZ) {
            guard let store else { throw DrawingStorageError.unavailable }
            var indices = try store.strokeIndices()
            indices.merge(pendingOrder) { _, new in new }
            for (id, pending) in pendingUpserts { indices[id] = pending.zIndex }
            for id in pendingDeletions { indices.removeValue(forKey: id) }
            return indices
        }
        for (stroke, id) in zip(strokes, ids) {
            let previous = old[id]
            guard let z = order.visible[id] else { throw DrawingStorageError.invalidStroke }
            if let previous,
               PKDrawing(strokes: [previous.local]) == PKDrawing(strokes: [stroke]) {
                let reordered = previous.record.withZIndex(z)
                if previous.record.zIndex != z {
                    changes.append(StrokeChange(before: previous.record, after: reordered))
                }
                newPage.append(VisibleStroke(record: reordered, local: previous.local))
                continue
            }
            let saved = try Self.record(for: stroke, id: id, z: z, surfaceOrigin: surfaceOrigin)
            changes.append(StrokeChange(before: previous?.record, after: saved))
            newPage.append(VisibleStroke(record: saved, local: stroke))
        }
        nextZ = order.nextZ
        ledger = newLedger
        visible = newPage
        drawing = current
        loadedStrokeCount = newPage.count
        guard !changes.isEmpty || !order.hiddenShifts.isEmpty else { return }
        stage(changes, shifts: order.hiddenShifts)
        registerInverse(of: changes, shifts: order.hiddenShifts)
        scheduleSave()
    }

    private static func translated(_ drawing: PKDrawing, by delta: CGPoint) -> PKDrawing {
        if delta == .zero { return drawing }
        return drawing.transformed(using: CGAffineTransform(translationX: delta.x, y: delta.y))
    }

    /// Keep archival path coordinates near zero. SQLite stores the world-space origin in Double.
    private static func record(for stroke: PKStroke, id: UUID, z: Int64,
                               surfaceOrigin: CGPoint) throws -> StoredStroke {
        let local = stroke.renderBounds
        guard !local.isNull, !local.isInfinite, local.minX.isFinite, local.minY.isFinite else {
            throw DrawingStorageError.invalidStroke
        }
        let bounds = local.offsetBy(dx: surfaceOrigin.x, dy: surfaceOrigin.y)
        let normalized = translated(PKDrawing(strokes: [stroke]), by: CGPoint(x: -local.minX, y: -local.minY))
        return StoredStroke(id: id, bounds: bounds, zIndex: z, data: normalized.dataRepresentation())
    }

    private static func decode(_ record: StoredStroke, origin: CGPoint) throws -> VisibleStroke {
        let archived = try PKDrawing(data: record.data)
        guard archived.strokes.count == 1, let stroke = archived.strokes.first else {
            throw DrawingStorageError.invalidStroke
        }
        let delta = CGPoint(x: record.bounds.minX - origin.x - stroke.renderBounds.minX,
                            y: record.bounds.minY - origin.y - stroke.renderBounds.minY)
        return VisibleStroke(record: record, local: translated(archived, by: delta).strokes[0])
    }

    private func displayPage(_ rect: CGRect, origin: CGPoint) throws {
        guard let store else { throw DrawingStorageError.unavailable }
        let signpost = OSSignpostID(log: Self.pageLog)
        os_signpost(.begin, log: Self.pageLog, name: "Load ink viewport", signpostID: signpost)
        defer {
            os_signpost(.end, log: Self.pageLog, name: "Load ink viewport", signpostID: signpost,
                        "resident=%d total=%d", loadedStrokeCount, strokeCount)
        }
        var rows = Dictionary(uniqueKeysWithValues: try store.strokes(in: rect).map { record in
            (record.id, pendingOrder[record.id].map(record.withZIndex) ?? record)
        })
        for id in pendingDeletions { rows.removeValue(forKey: id) }
        for (id, pending) in pendingUpserts {
            rows[id] = pending.bounds.intersects(rect) ? pending : nil
        }
        let cached = Dictionary(uniqueKeysWithValues: visible.map { ($0.record.id, $0) })
        let sorted = rows.values.sorted { $0.zIndex < $1.zIndex }
        let page = try sorted.map { row -> VisibleStroke in
            if origin == surfaceOrigin, let hit = cached[row.id],
               hit.record.zIndex == row.zIndex, hit.record.bounds == row.bounds, hit.record.data == row.data {
                return hit
            }
            return try Self.decode(row, origin: origin)
        }
        loadedWorldRect = rect
        surfaceOrigin = origin
        visible = page
        let local = PKDrawing(strokes: page.map(\.local))
        ledger.restore(page.map { StrokeDescriptor($0.local) }, ids: page.map { $0.record.id })
        applyingPage = true
        drawing = local
        if canvas?.drawing != local { canvas?.drawing = local }
        applyingPage = false
        if loadedStrokeCount != page.count { loadedStrokeCount = page.count }
        refreshTutorMarks()
    }

    private func stage(_ changes: [StrokeChange], shifts: [StrokeOrderShift]) {
        for shift in shifts {
            if let record = pendingUpserts[shift.id] {
                pendingUpserts[shift.id] = record.withZIndex(shift.to)
            } else {
                pendingOrder[shift.id] = shift.to
            }
        }
        var difference = 0
        for change in changes {
            if let after = change.after {
                pendingOrder.removeValue(forKey: after.id)
                pendingDeletions.remove(after.id)
                pendingUpserts[after.id] = after
                if change.before == nil { difference += 1 }
            } else if let before = change.before {
                pendingOrder.removeValue(forKey: before.id)
                pendingUpserts.removeValue(forKey: before.id)
                pendingDeletions.insert(before.id)
                difference -= 1
            }
        }
        if difference != 0 { strokeCount += difference }
        if !changes.isEmpty {
            if tutorFollowUp != nil { tutorFollowUp = nil }
            for change in changes {
                if let before = change.before { tutorDirtyRegion.record(before.bounds) }
                if let after = change.after { tutorDirtyRegion.record(after.bounds) }
            }
            inkActivity &+= 1
        }
    }

    private func registerInverse(of changes: [StrokeChange], shifts: [StrokeOrderShift]) {
        let needsGroup = !history.isUndoing && !history.isRedoing
        history.enableUndoRegistration()
        if needsGroup { history.beginUndoGrouping() }
        history.registerUndo(withTarget: self) { document in document.applyInverse(of: changes, shifts: shifts) }
        if needsGroup { history.endUndoGrouping() }
        history.disableUndoRegistration()
        objectWillChange.send()
    }

    private func applyInverse(of changes: [StrokeChange], shifts: [StrokeOrderShift]) {
        let inverse = changes.map { StrokeChange(before: $0.after, after: $0.before) }
        let inverseShifts = shifts.map { StrokeOrderShift(id: $0.id, from: $0.to, to: $0.from) }
        stage(inverse, shifts: inverseShifts)
        registerInverse(of: inverse, shifts: inverseShifts)
        do {
            if let loadedWorldRect { try displayPage(loadedWorldRect, origin: surfaceOrigin) }
            try commit()
        } catch { reportFailure() }
    }

    func undo() { if !toolActive, canUndo { history.undo() } }
    func redo() { if !toolActive, canRedo { history.redo() } }

    private func scheduleSave(after delay: TimeInterval = 0.5) {
        // Scrolling can produce a new camera every frame. Keep the first deadline so
        // a completed edit still reaches disk while the next gesture is in progress.
        guard scheduledSave == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.scheduledSave = nil
            // Only staged, completed edits are eligible. PencilKit owns the live stroke.
            do { try self.commit() }
            catch {
                if !self.retrySave(after: error) { self.reportFailure() }
            }
        }
        scheduledSave = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    @discardableResult
    private func retrySave(after error: Error) -> Bool {
        guard let delay = saveRetry.nextDelay(after: error) else { return false }
        scheduleSave(after: delay)
        return true
    }

    private func commit() throws {
        guard let store else { throw DrawingStorageError.unavailable }
        let editsInk = !pendingUpserts.isEmpty || !pendingDeletions.isEmpty || !pendingOrder.isEmpty
        if editsInk || cameraDirty || visibilityDirty {
            try store.commit(upserts: Array(pendingUpserts.values), deleting: Array(pendingDeletions),
                             reordering: pendingOrder,
                             camera: cameraDirty ? restoredCamera : nil,
                             aiLayerVisible: visibilityDirty ? aiLayerVisible : nil)
            pendingUpserts.removeAll()
            pendingDeletions.removeAll()
            pendingOrder.removeAll()
            cameraDirty = false
            visibilityDirty = false
            if editsInk { refreshTutorMarks() }
        }
        saveRetry.reset()
        if saveError != nil { saveError = nil; showSaveError = false }
    }

    func saveNow() {
        scheduledSave?.cancel()
        scheduledSave = nil
        saveRetry.reset()
        guard loadError == nil else { return }
        do {
            if !toolActive, let canvas { try capture(canvas) }
            try commit()
        } catch {
            retrySave(after: error)
            reportFailure()
        }
    }

    func exportBackup(to url: URL) throws {
        guard let store, loadError == nil else { throw DrawingStorageError.unavailable }
        if !toolActive, let canvas { try capture(canvas) }
        try commit()
        try store.export(to: url)
    }

    func flushPendingEdits() throws {
        guard store != nil, loadError == nil, !toolActive else { throw DrawingStorageError.unavailable }
        if let canvas { try capture(canvas) }
        try commit()
    }

    func drawingForExport(in region: CGRect) throws -> PKDrawing {
        try flushPendingEdits()
        guard let store else { throw DrawingStorageError.unavailable }
        let strokes = try store.strokes(in: region).map { try Self.decode($0, origin: region.origin).local }
        return PKDrawing(strokes: strokes)
    }

    func tutorMarksForExport(in region: CGRect) throws -> [TutorMark] {
        try flushPendingEdits()
        guard aiLayerVisible, let store, canUndoTutor else { return [] }
        let annotations = try store.tutorAnnotations(anchoredIn: region)
        guard !annotations.isEmpty else { return [] }
        let anchors = Dictionary(uniqueKeysWithValues: try store.strokes(in: region).map { ($0.id, $0.bounds) })
        return TutorMark.layout(annotations, anchors: anchors, in: region, sizeOfLabel: TutorInkCanvas.labelSize)
    }

    func createPracticeProblem(for selected: PracticeSkill?) throws -> PracticeCard {
        try flushPendingEdits()
        guard let viewport, let store else { throw DrawingStorageError.unavailable }
        practice = try store.startPractice(for: selected, in: viewport, avoiding: tutorMarks.map(\.frame))
        guard let problem = practice.current else { throw DrawingStorageError.unavailable }
        return problem
    }

    func revealPracticeHint(for id: UUID) throws {
        guard let store else { throw DrawingStorageError.unavailable }
        let result = try store.updatePractice { journal in
            if journal.current?.id == id { _ = journal.revealHint() }
        }
        practice = result.journal
    }

    func submitPracticeAnswer(_ answer: String, for id: UUID) throws -> PracticeGrade {
        guard let store else { throw DrawingStorageError.unavailable }
        let result = try store.updatePractice { journal in
            journal.current?.id == id ? journal.submit(answer) : .closed
        }
        practice = result.journal
        return result.value
    }

    private func reportFailure() {
        saveError = "노트를 읽거나 저장하지 못했습니다. 작성 중인 필기를 유지했습니다."
        showSaveError = true
    }
}
