import Foundation
import SQLite3

struct StoredStroke: Equatable {
    let id: UUID
    let bounds: CGRect
    let zIndex: Int64
    let data: Data

    func withZIndex(_ value: Int64) -> StoredStroke {
        StoredStroke(id: id, bounds: bounds, zIndex: value, data: data)
    }
}

struct NoteMetadata: Equatable {
    let noteID: UUID
    let revision: Int64
    let inkRevision: Int64
    let tutorEpoch: Int64
    let camera: CanvasCamera
    let aiLayerVisible: Bool
    let strokeCount: Int
    let nextZIndex: Int64
}

private struct StorageFailure: LocalizedError {
    let errorDescription: String?
    let sqliteCode: Int32?

    init(_ message: String, sqliteCode: Int32? = nil) {
        errorDescription = message
        self.sqliteCode = sqliteCode
    }

    init(_ db: OpaquePointer, sqliteCode: Int32) {
        self.init(String(cString: sqlite3_errmsg(db)), sqliteCode: sqliteCode)
    }
}

struct NoteSaveRetry {
    private static let delays: [TimeInterval] = [0.16, 0.32, 0.64, 1.28]
    private var retries = 0

    mutating func nextDelay(after error: Error) -> TimeInterval? {
        guard let code = (error as? StorageFailure)?.sqliteCode,
              code & 0xff == SQLITE_BUSY || code & 0xff == SQLITE_LOCKED,
              retries < Self.delays.count else { return nil }
        let delay = Self.delays[retries]
        retries += 1
        return delay
    }

    mutating func reset() { retries = 0 }
}

private enum SQLValue {
    case text(String), integer(Int64), real(Double), blob(Data), null
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private final class NoteStatement {
    let db: OpaquePointer
    let handle: OpaquePointer

    init(_ db: OpaquePointer, _ sql: String) throws {
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard status == SQLITE_OK, let statement else {
            throw StorageFailure(db, sqliteCode: status)
        }
        self.db = db
        self.handle = statement
    }

    deinit { sqlite3_finalize(handle) }

    func bind(_ values: [SQLValue]) throws {
        sqlite3_reset(handle)
        for (offset, value) in values.enumerated() {
            let i = Int32(offset + 1)
            let result: Int32
            switch value {
            case .text(let text): result = sqlite3_bind_text(handle, i, text, -1, sqliteTransient)
            case .integer(let integer): result = sqlite3_bind_int64(handle, i, integer)
            case .real(let number): result = sqlite3_bind_double(handle, i, number)
            case .blob(let data):
                result = data.withUnsafeBytes { buffer in
                    sqlite3_bind_blob64(handle, i, buffer.baseAddress, UInt64(buffer.count), sqliteTransient)
                }
            case .null: result = sqlite3_bind_null(handle, i)
            }
            guard result == SQLITE_OK else { throw StorageFailure(db, sqliteCode: result) }
        }
    }

    func next() throws -> Bool {
        let status = sqlite3_step(handle)
        switch status {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw StorageFailure(db, sqliteCode: status)
        }
    }

    func run(_ values: [SQLValue]) throws {
        try bind(values)
        guard try !next() else { throw StorageFailure("Unexpected database result.") }
    }

    func uuid(_ index: Int32) throws -> UUID {
        guard let id = UUID(uuidString: try text(index)) else {
            throw StorageFailure("The note contains an invalid identifier.")
        }
        return id
    }

    func text(_ index: Int32) throws -> String {
        guard let bytes = sqlite3_column_text(handle, index) else { throw StorageFailure("Missing note text.") }
        return String(cString: bytes)
    }

    func data(_ index: Int32) throws -> Data {
        guard let bytes = sqlite3_column_blob(handle, index) else { throw StorageFailure("Missing note data.") }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(handle, index)))
    }

    func rect(startingAt index: Int32) -> CGRect {
        let x = sqlite3_column_double(handle, index), y = sqlite3_column_double(handle, index + 2)
        return CGRect(x: x, y: y, width: sqlite3_column_double(handle, index + 1) - x,
                      height: sqlite3_column_double(handle, index + 3) - y)
    }
}

/// Stores note content and world geometry. The lock serializes every access to the connection.
final class NoteStore: @unchecked Sendable {
    private let db: OpaquePointer
    private let lock = NSLock()
    private static let schemaVersion = 5
    private static let applicationID = 0x5244434E // RDCN

    init(url: URL, busyTimeoutMilliseconds: Int32 = 2_000) throws {
        var connection: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard result == SQLITE_OK, let connection else {
            let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "Cannot open note."
            sqlite3_close(connection)
            throw StorageFailure(message, sqliteCode: result)
        }
        db = connection
        sqlite3_busy_timeout(db, 2_000)
        try execute("PRAGMA synchronous = FULL")
        try transaction {
            let version = try integer("PRAGMA user_version")
            let application = try integer("PRAGMA application_id")
            if version == 0 && application == 0 {
                guard try integer("SELECT count(*) FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'") == 0 else {
                    throw StorageFailure("Unrecognized note database.")
                }
                try createSchema()
            } else if !(1...Self.schemaVersion).contains(version) || application != Self.applicationID {
                throw StorageFailure("Unsupported note format or schema version.")
            }
            if version < 2 { try migrateTutorLayer() }
            if version < 3 { try createTutorHistory() }
            if version < 4 { try createResources() }
            if version < 5 { try createPracticeAndPrivacyState() }
        }
        sqlite3_busy_timeout(db, busyTimeoutMilliseconds)
    }

    deinit { sqlite3_close(db) }

    private func execute(_ sql: String) throws {
        let status = sqlite3_exec(db, sql, nil, nil, nil)
        guard status == SQLITE_OK else {
            throw StorageFailure(db, sqliteCode: status)
        }
    }

    private func integer(_ sql: String) throws -> Int {
        let query = try NoteStatement(db, sql)
        guard try query.next() else { throw StorageFailure("Missing database value.") }
        return Int(sqlite3_column_int64(query.handle, 0))
    }

    private func transaction<T>(_ work: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try work()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func createSchema() throws {
        // The virtual module is a build option. A SQLite build without it can still create
        // notes using ordinary indexed intervals with the same insertion/query semantics.
        let spatialTable: String
        if try integer("SELECT count(*) FROM pragma_module_list WHERE name='rtree'") == 1 {
            spatialTable = "CREATE VIRTUAL TABLE stroke_bounds USING rtree(key, x0, x1, y0, y1);"
        } else {
            spatialTable = """
                CREATE TABLE stroke_bounds (key INTEGER PRIMARY KEY, x0 REAL, x1 REAL, y0 REAL, y1 REAL);
                CREATE INDEX bounds_left ON stroke_bounds(x0);
                CREATE INDEX bounds_right ON stroke_bounds(x1);
                """
        }
        try execute("""
            CREATE TABLE note (
                singleton INTEGER PRIMARY KEY CHECK(singleton = 1), id TEXT NOT NULL,
                revision INTEGER NOT NULL DEFAULT 0, x REAL NOT NULL DEFAULT 0,
                y REAL NOT NULL DEFAULT 0, scale REAL NOT NULL DEFAULT 1 CHECK(scale > 0),
                ai_visible INTEGER NOT NULL DEFAULT 1
            );
            CREATE TABLE strokes (
                key INTEGER PRIMARY KEY, uuid TEXT NOT NULL UNIQUE, z INTEGER NOT NULL,
                x0 REAL NOT NULL, x1 REAL NOT NULL, y0 REAL NOT NULL, y1 REAL NOT NULL,
                ink BLOB NOT NULL CHECK(length(ink) > 0)
            );
            CREATE INDEX strokes_z ON strokes(z);
            \(spatialTable)
            CREATE TRIGGER stroke_insert AFTER INSERT ON strokes BEGIN
                INSERT INTO stroke_bounds VALUES (new.key, new.x0, new.x1, new.y0, new.y1);
            END;
            CREATE TRIGGER stroke_move AFTER UPDATE OF x0, x1, y0, y1 ON strokes BEGIN
                UPDATE stroke_bounds SET x0=new.x0, x1=new.x1, y0=new.y0, y1=new.y1 WHERE key=new.key;
            END;
            CREATE TRIGGER stroke_remove AFTER DELETE ON strokes BEGIN
                DELETE FROM stroke_bounds WHERE key=old.key;
            END;
            PRAGMA application_id = \(Self.applicationID);
            PRAGMA user_version = 1;
            """)
        let insert = try NoteStatement(db, "INSERT INTO note(singleton, id) VALUES (1, ?)")
        try insert.run([.text(UUID().uuidString)])
    }

    private func migrateTutorLayer() throws {
        try execute("""
            ALTER TABLE note ADD COLUMN ink_revision INTEGER NOT NULL DEFAULT 0;
            UPDATE note SET ink_revision=revision;
            CREATE TABLE tutor_batches (
                sequence INTEGER PRIMARY KEY, request_id TEXT NOT NULL UNIQUE, ink_revision INTEGER NOT NULL,
                model TEXT NOT NULL, reason TEXT NOT NULL, undone INTEGER NOT NULL DEFAULT 0,
                version INTEGER NOT NULL DEFAULT 1
            );
            CREATE TABLE tutor_annotations (
                sequence INTEGER PRIMARY KEY, uuid TEXT NOT NULL UNIQUE, target_id TEXT NOT NULL,
                batch_sequence INTEGER NOT NULL REFERENCES tutor_batches(sequence), action BLOB NOT NULL
            );
            CREATE INDEX tutor_annotations_target ON tutor_annotations(target_id);
            PRAGMA user_version = 2;
            """)
    }

    private func createTutorHistory() throws {
        try execute("""
            CREATE TABLE tutor_events (
                sequence INTEGER PRIMARY KEY, request_id TEXT NOT NULL UNIQUE, revision INTEGER NOT NULL,
                x0 REAL NOT NULL, x1 REAL NOT NULL, y0 REAL NOT NULL, y1 REAL NOT NULL, event BLOB NOT NULL
            );
            PRAGMA user_version = 3;
            """)
    }

    private func createResources() throws {
        try execute("""
            CREATE TABLE note_pdfs (
                sequence INTEGER PRIMARY KEY, id TEXT NOT NULL UNIQUE, title TEXT NOT NULL,
                title_key TEXT NOT NULL, page_count INTEGER NOT NULL CHECK(page_count > 0),
                pdf BLOB NOT NULL CHECK(length(pdf) > 0)
            );
            CREATE TABLE note_pdf_pages (
                id TEXT PRIMARY KEY NOT NULL, material_id TEXT NOT NULL REFERENCES note_pdfs(id),
                page_index INTEGER NOT NULL CHECK(page_index >= 0),
                x0 REAL NOT NULL, x1 REAL NOT NULL CHECK(x1 > x0),
                y0 REAL NOT NULL, y1 REAL NOT NULL CHECK(y1 > y0),
                page_text TEXT NOT NULL, text_key TEXT NOT NULL, UNIQUE(material_id,page_index)
            );
            CREATE INDEX note_pdf_pages_top ON note_pdf_pages(y0);
            CREATE INDEX note_pdf_pages_bottom ON note_pdf_pages(y1);
            CREATE TABLE note_source_links (
                sequence INTEGER PRIMARY KEY, id TEXT NOT NULL UNIQUE, title TEXT NOT NULL, url TEXT NOT NULL
            );
            PRAGMA user_version = 4;
            """)
    }

    private func createPracticeAndPrivacyState() throws {
        try execute("""
            ALTER TABLE note ADD COLUMN tutor_epoch INTEGER NOT NULL DEFAULT 0;
            CREATE TABLE note_practice (
                singleton INTEGER PRIMARY KEY CHECK(singleton=1), state BLOB NOT NULL
            );
            PRAGMA user_version = 5;
            """)
    }

    func metadata() throws -> NoteMetadata {
        try lock.withLock {
            let query = try NoteStatement(db, """
                SELECT id,revision,x,y,scale,ai_visible,(SELECT count(*) FROM strokes),
                       (SELECT coalesce(max(z), -1) + 1 FROM strokes), ink_revision,tutor_epoch
                FROM note WHERE singleton=1
                """)
            guard try query.next() else { throw StorageFailure("Missing note metadata.") }
            let row = query.handle
            let origin = CGPoint(x: sqlite3_column_double(row, 2), y: sqlite3_column_double(row, 3))
            return NoteMetadata(noteID: try query.uuid(0), revision: sqlite3_column_int64(row, 1),
                                inkRevision: sqlite3_column_int64(row, 8),
                                tutorEpoch: sqlite3_column_int64(row, 9),
                                camera: CanvasCamera(origin: origin, scale: sqlite3_column_double(row, 4)),
                                aiLayerVisible: sqlite3_column_int(row, 5) != 0,
                                strokeCount: Int(sqlite3_column_int64(row, 6)),
                                nextZIndex: sqlite3_column_int64(row, 7))
        }
    }

    func strokeGeometry(in region: CGRect) throws -> [CGRect] {
        guard Self.isIndexable(region) else { throw StorageFailure("Invalid viewport bounds.") }
        return try lock.withLock {
            let query = try NoteStatement(db, """
                SELECT s.x0,s.x1,s.y0,s.y1
                FROM stroke_bounds AS b CROSS JOIN strokes AS s ON s.key = b.key
                WHERE b.x0 <= ?1 AND b.x1 >= ?2 AND b.y0 <= ?3 AND b.y1 >= ?4
                  AND s.x0 <= ?1 AND s.x1 >= ?2 AND s.y0 <= ?3 AND s.y1 >= ?4
                """)
            try query.bind([.real(region.maxX), .real(region.minX), .real(region.maxY), .real(region.minY)])
            var bounds: [CGRect] = []
            while try query.next() { bounds.append(query.rect(startingAt: 0)) }
            return bounds
        }
    }

    func practiceJournal() throws -> PracticeJournal { try lock.withLock { try readPracticeJournal() } }

    func startPractice(for selected: PracticeSkill?, in viewport: CGRect,
                       avoiding tutorBounds: [CGRect]) throws -> PracticeJournal {
        guard Self.isIndexable(viewport), !viewport.isEmpty else { throw StorageFailure("Invalid practice viewport.") }
        let revision = try metadata().revision
        let source = try practiceSource(in: viewport, matching: selected)
        let skill = selected ?? source?.skill ?? .addition
        let anchor = try source?.bounds ?? strokes(in: viewport, newest: 1).first?.bounds.intersection(viewport)
            ?? CGRect(x: viewport.midX, y: viewport.midY, width: 1, height: 1)
        let expanded = viewport.insetBy(dx: -640, dy: -480)
        let size = CGSize(width: 290, height: 138)
        let occupancy = try strokeGeometry(in: expanded) + resourceBounds(in: expanded) + tutorBounds
        let preferred = TutorPlacement.label(size: size, near: anchor, toward: .nearRight,
                                             occupancy: occupancy, inside: viewport)
        var frame = preferred ?? TutorPlacement.label(size: size, near: anchor, toward: .nearRight,
                                                       occupancy: occupancy, inside: expanded)
        if frame == nil {
            for offset in 0..<16 {
                let candidate = CGRect(x: viewport.maxX + 50 + CGFloat(offset) * (size.width + 26),
                                       y: viewport.minY + 40, width: size.width, height: size.height)
                let margin = candidate.insetBy(dx: -12, dy: -12)
                if !TutorPlacement.obstructs(candidate, in: tutorBounds),
                   try strokeGeometry(in: margin).isEmpty, try resourceBounds(in: margin).isEmpty {
                    frame = candidate
                    break
                }
            }
        }
        guard let frame else { throw StorageFailure("No room for a practice problem.") }
        return try updatePractice(matchingRevision: revision) { journal in
            journal.start(skill: skill, excluding: source?.transcript, frame: frame)
        }.journal
    }

    private func practiceSource(in viewport: CGRect, matching selected: PracticeSkill?) throws
        -> (skill: PracticeSkill, transcript: String, bounds: CGRect)? {
        try lock.withLock {
            let query = try NoteStatement(db, """
                SELECT event, x0, x1, y0, y1 FROM tutor_events
                WHERE revision <= (SELECT ink_revision FROM note WHERE singleton=1)
                  AND x0 <= ? AND x1 >= ? AND y0 <= ? AND y1 >= ?
                ORDER BY revision DESC, sequence DESC LIMIT 24
                """)
            try query.bind([.real(viewport.maxX), .real(viewport.minX), .real(viewport.maxY), .real(viewport.minY)])
            let decoder = JSONDecoder()
            while try query.next() {
                let event = try decoder.decode(TutorRecentEvent.self, from: query.data(0))
                let bounds = query.rect(startingAt: 1).intersection(viewport)
                if !bounds.isEmpty, let skill = PracticeSkill.related(to: event), selected == nil || selected == skill {
                    return (skill, event.transcript, bounds)
                }
            }
            return nil
        }
    }

    private func readPracticeJournal() throws -> PracticeJournal {
        let query = try NoteStatement(db, "SELECT state FROM note_practice WHERE singleton=1")
        guard try query.next() else { return PracticeJournal() }
        return try JSONDecoder().decode(PracticeJournal.self, from: query.data(0))
    }

    func updatePractice<Value>(matchingRevision expected: Int64? = nil,
                               _ update: (inout PracticeJournal) throws -> Value) throws -> (journal: PracticeJournal, value: Value) {
        try lock.withLock {
            try transaction {
                if let expected, try integer("SELECT revision FROM note WHERE singleton=1") != expected {
                    throw StorageFailure("The note changed during practice placement.")
                }
                let original = try readPracticeJournal()
                var journal = original
                let result = try update(&journal)
                if journal != original {
                    let save = try NoteStatement(db, """
                        INSERT INTO note_practice(singleton,state) VALUES(1,?)
                        ON CONFLICT(singleton) DO UPDATE SET state=excluded.state
                        """)
                    try save.run([.blob(try JSONEncoder().encode(journal))])
                    try execute("UPDATE note SET revision=revision+1 WHERE singleton=1")
                }
                return (journal, result)
            }
        }
    }

    func strokes(in worldRect: CGRect, newest limit: Int? = nil) throws -> [StoredStroke] {
        guard Self.isIndexable(worldRect) else { throw StorageFailure("Invalid viewport bounds.") }
        return try lock.withLock {
            // R*Tree bounds are outward-rounded floats. The second check uses original doubles
            // so two nearby strokes remain distinguishable even at distant world coordinates.
            let order = limit == nil ? "s.z, s.key" : "s.z DESC, s.key DESC"
            let query = try NoteStatement(db, """
                SELECT s.uuid,s.z,s.x0,s.y0,s.x1,s.y1,s.ink
                FROM stroke_bounds AS b CROSS JOIN strokes AS s ON s.key = b.key
                WHERE b.x0 <= ?1 AND b.x1 >= ?2 AND b.y0 <= ?3 AND b.y1 >= ?4
                  AND s.x0 <= ?1 AND s.x1 >= ?2 AND s.y0 <= ?3 AND s.y1 >= ?4
                ORDER BY \(order) LIMIT ?5
                """)
            try query.bind([.real(worldRect.maxX), .real(worldRect.minX), .real(worldRect.maxY),
                            .real(worldRect.minY), .integer(Int64(limit.map { max(0, $0) } ?? -1))])
            var result: [StoredStroke] = []
            while try query.next() {
                let row = query.handle
                let x = sqlite3_column_double(row, 2), y = sqlite3_column_double(row, 3)
                let bounds = CGRect(x: x, y: y, width: sqlite3_column_double(row, 4) - x,
                                    height: sqlite3_column_double(row, 5) - y)
                result.append(StoredStroke(id: try query.uuid(0), bounds: bounds,
                                           zIndex: sqlite3_column_int64(row, 1), data: try query.data(6)))
            }
            return limit == nil ? result : Array(result.reversed())
        }
    }

    func strokeIndices() throws -> [UUID: Int64] {
        try lock.withLock {
            let query = try NoteStatement(db, "SELECT uuid, z FROM strokes")
            var result: [UUID: Int64] = [:]
            while try query.next() { result[try query.uuid(0)] = sqlite3_column_int64(query.handle, 1) }
            return result
        }
    }

    func commit(upserts: [StoredStroke] = [], deleting ids: [UUID] = [], reordering: [UUID: Int64] = [:],
                camera: CanvasCamera? = nil, aiLayerVisible: Bool? = nil) throws {
        let editsInk = !upserts.isEmpty || !ids.isEmpty || !reordering.isEmpty
        guard editsInk || camera != nil || aiLayerVisible != nil else { return }
        try lock.withLock {
            try transaction {
                if !ids.isEmpty {
                    let remove = try NoteStatement(db, "DELETE FROM strokes WHERE uuid=?")
                    for id in ids { try remove.run([.text(id.uuidString)]) }
                }
                if !reordering.isEmpty {
                    let reorder = try NoteStatement(db, "UPDATE strokes SET z=? WHERE uuid=?")
                    for (id, z) in reordering {
                        guard z >= 0, z < Int64.max else { throw StorageFailure("Invalid stroke order.") }
                        try reorder.run([.integer(z), .text(id.uuidString)])
                    }
                }
                if !upserts.isEmpty {
                    let write = try NoteStatement(db, """
                        INSERT INTO strokes(uuid,z,x0,x1,y0,y1,ink) VALUES(?,?,?,?,?,?,?)
                        ON CONFLICT(uuid) DO UPDATE SET z=excluded.z, x0=excluded.x0, x1=excluded.x1,
                            y0=excluded.y0, y1=excluded.y1, ink=excluded.ink
                        """)
                    for stroke in upserts {
                        guard Self.isIndexable(stroke.bounds), !stroke.data.isEmpty,
                              stroke.zIndex >= 0, stroke.zIndex < Int64.max else {
                            throw StorageFailure("Invalid stroke geometry, order or data.")
                        }
                        let r = stroke.bounds
                        try write.run([.text(stroke.id.uuidString), .integer(stroke.zIndex), .real(r.minX),
                                       .real(r.maxX), .real(r.minY), .real(r.maxY), .blob(stroke.data)])
                    }
                }
                if let camera, !(camera.origin.x.isFinite && camera.origin.y.isFinite && camera.scale.isFinite) {
                    throw StorageFailure("Invalid camera position.")
                }
                let update = try NoteStatement(db, """
                    UPDATE note SET revision=revision+1, ink_revision=ink_revision+?, x=coalesce(?,x), y=coalesce(?,y),
                        scale=coalesce(?,scale), ai_visible=coalesce(?,ai_visible) WHERE singleton=1
                    """)
                try update.run([.integer(editsInk ? 1 : 0),
                                camera.map { .real($0.origin.x) } ?? .null, camera.map { .real($0.origin.y) } ?? .null,
                                camera.map { .real($0.scale) } ?? .null, aiLayerVisible.map { .integer($0 ? 1 : 0) } ?? .null])
            }
        }
    }

    /// The tutor only inserts annotation rows. Request IDs remain reserved after undo.
    func applyTutorProposal(_ proposal: TutorProposal) throws -> Bool {
        try lock.withLock {
            var applied = false
            try transaction {
                let context = proposal.context
                let note = try NoteStatement(db, "SELECT id, ink_revision, tutor_epoch FROM note WHERE singleton=1")
                guard try note.next(), try note.uuid(0) == context.noteID,
                      sqlite3_column_int64(note.handle, 2) == context.policyEpoch else { throw TutorProposalError.stale }
                let request = try NoteStatement(db, "SELECT 1 FROM tutor_batches WHERE request_id=?")
                try request.bind([.text(context.requestID.uuidString)])
                if try request.next() { return }
                guard sqlite3_column_int64(note.handle, 1) == context.inkRevision else { throw TutorProposalError.stale }

                let insertBatch = try NoteStatement(db, """
                    INSERT INTO tutor_batches(request_id,ink_revision,model,reason) VALUES (?,?,?,?)
                    """)
                try insertBatch.run([.text(context.requestID.uuidString), .integer(context.inkRevision),
                                     .text(proposal.model), .text(proposal.reason)])
                let batch = sqlite3_last_insert_rowid(db)
                let stroke = try NoteStatement(db, "SELECT 1 FROM strokes WHERE uuid=?")
                let insertAnnotation = try NoteStatement(db, """
                    INSERT INTO tutor_annotations(uuid,target_id,batch_sequence,action) VALUES (?,?,?,?)
                    """)
                let encoder = JSONEncoder()
                for action in proposal.actions {
                    try stroke.bind([.text(action.targetID.uuidString)])
                    guard try stroke.next() else { throw TutorProposalError.missingAnchor }
                    try stroke.bind([.text(action.id.uuidString)])
                    guard try !stroke.next() else { throw TutorProposalError.invalidResponse }
                    try insertAnnotation.run([.text(action.id.uuidString), .text(action.targetID.uuidString),
                                              .integer(batch), .blob(try encoder.encode(action))])
                }
                try execute("UPDATE note SET revision=revision+1 WHERE singleton=1")
                applied = true
            }
            return applied
        }
    }

    func undoLatestTutorBatch() throws -> Bool {
        try lock.withLock {
            var undone = false
            try transaction {
                try execute("""
                    UPDATE tutor_batches SET undone=1, version=version+1 WHERE sequence=(
                        SELECT sequence FROM tutor_batches WHERE undone=0 ORDER BY sequence DESC LIMIT 1
                    )
                    """)
                undone = sqlite3_changes(db) > 0
                if undone { try execute("UPDATE note SET revision=revision+1 WHERE singleton=1") }
            }
            return undone
        }
    }

    func hasActiveTutorBatch() throws -> Bool {
        try lock.withLock {
            let query = try NoteStatement(db, "SELECT 1 FROM tutor_batches WHERE undone=0 LIMIT 1")
            return try query.next()
        }
    }

    func allRecentTutorEvents() throws -> [TutorRecentEvent] {
        try lock.withLock {
            let query = try NoteStatement(db, "SELECT event FROM tutor_events ORDER BY sequence DESC LIMIT 24")
            let decoder = JSONDecoder()
            var history: [TutorRecentEvent] = []
            while try query.next() { history.append(try decoder.decode(TutorRecentEvent.self, from: query.data(0))) }
            return history
        }
    }

    func eraseTutorData() throws {
        try lock.withLock {
            let previous = try integer("PRAGMA secure_delete")
            try execute("PRAGMA secure_delete = ON")
            defer { try? execute("PRAGMA secure_delete = \(previous)") }
            try transaction {
                try execute("""
                    DELETE FROM tutor_annotations;
                    DELETE FROM tutor_batches;
                    DELETE FROM tutor_events;
                    UPDATE note SET tutor_epoch=tutor_epoch+1,revision=revision+1 WHERE singleton=1;
                    """)
            }
        }
    }

    /// Follow the anchor's current geometry, including moves and deletion from another page.
    func tutorAnnotations(anchoredIn rect: CGRect) throws -> [TutorAnnotation] {
        guard Self.isIndexable(rect) else { return [] }
        return try lock.withLock {
            let query = try NoteStatement(db, """
                SELECT b.request_id,b.ink_revision,b.model,b.reason,b.version,a.action
                FROM stroke_bounds AS r
                CROSS JOIN strokes AS s ON s.key=r.key
                JOIN tutor_annotations AS a ON a.target_id=s.uuid
                JOIN tutor_batches AS b ON b.sequence=a.batch_sequence
                WHERE b.undone=0 AND r.x0 <= ?1 AND r.x1 >= ?2 AND r.y0 <= ?3 AND r.y1 >= ?4
                    AND s.x0 <= ?1 AND s.x1 >= ?2 AND s.y0 <= ?3 AND s.y1 >= ?4
                ORDER BY b.sequence, a.sequence
                """)
            try query.bind([.real(rect.maxX), .real(rect.minX), .real(rect.maxY), .real(rect.minY)])
            let decoder = JSONDecoder()
            var result: [TutorAnnotation] = []
            while try query.next() {
                let action = try decoder.decode(TutorAction.self, from: query.data(5))
                result.append(TutorAnnotation(requestID: try query.uuid(0), inkRevision: sqlite3_column_int64(query.handle, 1),
                                              model: try query.text(2), reason: try query.text(3),
                                              version: sqlite3_column_int64(query.handle, 4), action: action))
            }
            return result
        }
    }

    func tutorHistory(near rect: CGRect, before revision: Int64) throws -> [TutorRecentEvent] {
        guard Self.isIndexable(rect) else { return [] }
        return try lock.withLock {
            let query = try NoteStatement(db, """
                SELECT event FROM tutor_events
                WHERE revision < ? AND x0 <= ? AND x1 >= ? AND y0 <= ? AND y1 >= ?
                ORDER BY sequence DESC LIMIT 3
                """)
            try query.bind([.integer(revision), .real(rect.maxX), .real(rect.minX),
                            .real(rect.maxY), .real(rect.minY)])
            let decoder = JSONDecoder()
            var events: [TutorRecentEvent] = []
            while try query.next() { events.append(try decoder.decode(TutorRecentEvent.self, from: query.data(0))) }
            return events.reversed()
        }
    }

    func currentTutorFollowUp() throws -> TutorFollowUp? {
        try lock.withLock {
            let query = try NoteStatement(db, """
                SELECT request_id, event, x0, x1, y0, y1 FROM tutor_events
                WHERE revision = (SELECT ink_revision FROM note WHERE singleton=1)
                ORDER BY sequence DESC LIMIT 1
                """)
            guard try query.next() else { return nil }
            let event = try JSONDecoder().decode(TutorRecentEvent.self, from: query.data(1))
            let bounds = query.rect(startingAt: 2)
            guard event.isFollowUp == true, !event.feedback.isEmpty, Self.isIndexable(bounds) else { return nil }
            return TutorFollowUp(requestID: try query.uuid(0), text: event.feedback, anchor: bounds)
        }
    }

    func recordTutorEvent(_ event: TutorRecentEvent, crop: CGRect, for context: TutorContext) throws {
        guard event.revision == context.inkRevision, Self.isIndexable(crop),
              event.transcript.utf8.count <= 1_024, event.feedback.utf8.count <= 512 else {
            throw StorageFailure("Invalid tutor history.")
        }
        let payload = try JSONEncoder().encode(event)
        try lock.withLock {
            try transaction {
                let note = try NoteStatement(db, "SELECT id, ink_revision, tutor_epoch FROM note WHERE singleton=1")
                guard try note.next(), try note.uuid(0) == context.noteID,
                      sqlite3_column_int64(note.handle, 1) == context.inkRevision,
                      sqlite3_column_int64(note.handle, 2) == context.policyEpoch else { throw TutorProposalError.stale }
                let insert = try NoteStatement(db, """
                    INSERT INTO tutor_events(request_id,revision,x0,x1,y0,y1,event) VALUES (?,?,?,?,?,?,?)
                    ON CONFLICT(request_id) DO NOTHING
                    """)
                try insert.run([.text(context.requestID.uuidString), .integer(context.inkRevision),
                                .real(crop.minX), .real(crop.maxX), .real(crop.minY), .real(crop.maxY), .blob(payload)])
                try execute("""
                    DELETE FROM tutor_events WHERE sequence NOT IN (
                        SELECT sequence FROM tutor_events ORDER BY sequence DESC LIMIT 24
                    )
                    """)
            }
        }
    }

    func insertPDF(_ source: NotePDFImport, beside viewport: CGRect) throws -> NotePDFMaterial {
        guard !source.data.isEmpty, !source.pages.isEmpty else { throw NoteResourceError.invalidPDF }
        guard source.data.count <= NotePDFImport.maximumFileBytes else { throw NoteResourceError.fileTooLarge }
        guard source.pages.count <= NotePDFImport.maximumPages else { throw NoteResourceError.tooManyPages }
        guard Self.isIndexable(viewport), !viewport.isEmpty else { throw NoteResourceError.noViewport }
        let title = NoteResourceText.cleaned(NoteResourceText.bounded(source.title, bytes: 512))
        let material = NotePDFMaterial(id: UUID(), title: title.isEmpty ? "PDF" : title, pageCount: source.pages.count)
        // Use world points near the source dimensions and fit oversized sheets on the canvas.
        let sizes = try source.pages.map { page in
            guard NotePDFImport.supports(page.size) else { throw NoteResourceError.invalidPage }
            let scale = min(1, 900 / max(page.size.width, page.size.height))
            return CGSize(width: page.size.width * scale, height: page.size.height * scale)
        }
        let pageGap: CGFloat = 32
        let height = sizes.reduce(0) { $0 + $1.height } + pageGap * CGFloat(sizes.count - 1)
        let width = sizes.map(\.width).max() ?? 0
        try lock.withLock {
            try transaction {
                let maxBytes = 256 * 1024 * 1024
                guard try integer("SELECT count(*) FROM note_pdfs") < 32,
                      try integer("SELECT coalesce(sum(length(pdf)),0) FROM note_pdfs") <= maxBytes - source.data.count
                else { throw NoteResourceError.libraryFull }
                let origin = try pdfOrigin(beside: viewport, size: CGSize(width: width, height: height))
                let id = SQLValue.text(material.id.uuidString)
                let insertPDF = try NoteStatement(db, """
                    INSERT INTO note_pdfs(id,title,title_key,page_count,pdf) VALUES(?,?,?,?,?)
                    """)
                try insertPDF.run([id, .text(material.title), .text(NoteResourceText.key(material.title)),
                                   .integer(Int64(material.pageCount)), .blob(source.data)])
                let insertPage = try NoteStatement(db, """
                    INSERT INTO note_pdf_pages(id,material_id,page_index,x0,x1,y0,y1,page_text,text_key)
                    VALUES(?,?,?,?,?,?,?,?,?)
                    """)
                var y = origin.y
                for (index, size) in sizes.enumerated() {
                    let frame = CGRect(origin: CGPoint(x: origin.x, y: y), size: size)
                    guard frame.maxX > frame.minX, frame.maxY > frame.minY else { throw NoteResourceError.noSpace }
                    let text = NoteResourceText.bounded(source.pages[index].text, bytes: NotePDFImport.maximumPageTextBytes)
                    try insertPage.run([.text(UUID().uuidString), id, .integer(Int64(index)),
                                        .real(frame.minX), .real(frame.maxX), .real(frame.minY), .real(frame.maxY),
                                        .text(text), .text(NoteResourceText.key(text))])
                    y = frame.maxY + pageGap
                }
                try execute("UPDATE note SET revision=revision+1 WHERE singleton=1")
            }
        }
        return material
    }

    private func pdfOrigin(beside viewport: CGRect, size: CGSize) throws -> CGPoint {
        let gap: CGFloat = 44
        let practice = (try? readPracticeJournal())?.current?.frame
        var candidate = CGRect(origin: CGPoint(x: viewport.maxX + gap, y: viewport.minY), size: size)
        let rightEdge = try NoteStatement(db, """
            SELECT max(edge) FROM (
                SELECT max(s.x1) AS edge FROM stroke_bounds AS b CROSS JOIN strokes AS s ON s.key=b.key
                WHERE b.x0 <= ?1 AND b.x1 >= ?2 AND b.y0 <= ?3 AND b.y1 >= ?4
                  AND s.x0 <= ?1 AND s.x1 >= ?2 AND s.y0 <= ?3 AND s.y1 >= ?4
                UNION ALL
                SELECT max(x1) AS edge FROM note_pdf_pages
                WHERE x0 <= ?1 AND x1 >= ?2 AND y0 <= ?3 AND y1 >= ?4
            )
            """)
        // Probe adjacent strips and skip to the right edge of whatever blocked each strip.
        for _ in 0..<64 {
            guard Self.isIndexable(candidate), candidate.minX > viewport.maxX else { break }
            try rightEdge.bind([.real(candidate.maxX), .real(candidate.minX), .real(candidate.maxY), .real(candidate.minY)])
            guard try rightEdge.next() else { break }
            let fileOrInkEdge: CGFloat? = sqlite3_column_type(rightEdge.handle, 0) != SQLITE_NULL
                ? CGFloat(sqlite3_column_double(rightEdge.handle, 0)) : nil
            let practiceEdge = practice.flatMap { candidate.intersects($0) ? $0.maxX : nil }
            guard let edge = [fileOrInkEdge, practiceEdge].compactMap({ $0 }).max() else { return candidate.origin }
            let nextX = edge + gap
            guard nextX > candidate.minX else { break }
            candidate.origin.x = nextX
        }
        throw NoteResourceError.noSpace
    }

    func pdfMaterials() throws -> [NotePDFMaterial] {
        try lock.withLock {
            let query = try NoteStatement(db, "SELECT id,title,page_count FROM note_pdfs ORDER BY sequence")
            var materials: [NotePDFMaterial] = []
            while try query.next() {
                materials.append(NotePDFMaterial(id: try query.uuid(0), title: try query.text(1),
                                                pageCount: Int(sqlite3_column_int64(query.handle, 2))))
            }
            return materials
        }
    }

    func pdfData(for materialID: UUID) throws -> Data {
        try lock.withLock {
            let query = try NoteStatement(db, "SELECT length(pdf),pdf FROM note_pdfs WHERE id=?")
            try query.bind([.text(materialID.uuidString)])
            guard try query.next() else { throw NoteResourceError.missingPDF }
            guard (1...Int64(NotePDFImport.maximumFileBytes)).contains(sqlite3_column_int64(query.handle, 0))
            else { throw NoteResourceError.fileTooLarge }
            return try query.data(1)
        }
    }

    func pdfPages(for materialID: UUID) throws -> [NotePDFPage] {
        try lock.withLock {
            let query = try NoteStatement(db, """
                SELECT id,material_id,page_index,x0,x1,y0,y1 FROM note_pdf_pages
                WHERE material_id=? ORDER BY page_index
                """)
            try query.bind([.text(materialID.uuidString)])
            return try readPDFPages(query)
        }
    }

    func pdfPages(in region: CGRect) throws -> [NotePDFPage] {
        guard Self.isIndexable(region), !region.isEmpty else { return [] }
        return try lock.withLock {
            let query = try NoteStatement(db, """
                SELECT id,material_id,page_index,x0,x1,y0,y1 FROM note_pdf_pages
                WHERE x0 < ? AND x1 > ? AND y0 < ? AND y1 > ? ORDER BY y0,x0
                """)
            try query.bind([.real(region.maxX), .real(region.minX), .real(region.maxY), .real(region.minY)])
            return try readPDFPages(query)
        }
    }

    func resourceBounds(in region: CGRect) throws -> [CGRect] {
        try pdfPages(in: region).map(\.frame)
    }

    private func readPDFPages(_ query: NoteStatement) throws -> [NotePDFPage] {
        var pages: [NotePDFPage] = []
        while try query.next() { pages.append(try pdfPage(from: query)) }
        return pages
    }

    private func pdfPage(from query: NoteStatement) throws -> NotePDFPage {
        let frame = query.rect(startingAt: 3)
        guard Self.isIndexable(frame), !frame.isEmpty else { throw NoteResourceError.invalidPage }
        return NotePDFPage(id: try query.uuid(0), materialID: try query.uuid(1),
                           index: Int(sqlite3_column_int64(query.handle, 2)), frame: frame)
    }

    func insertSourceLink(title: String, address: String) throws -> NoteSourceLink {
        guard let url = NoteSourceLink.httpsURL(address), let host = url.host else { throw NoteResourceError.invalidLink }
        let title = NoteResourceText.cleaned(NoteResourceText.bounded(title, bytes: 512))
        let link = NoteSourceLink(id: UUID(), title: title.isEmpty ? host : title, url: url)
        try lock.withLock {
            try transaction {
                guard try integer("SELECT count(*) FROM note_source_links") < 128 else {
                    throw NoteResourceError.libraryFull
                }
                let insert = try NoteStatement(db, "INSERT INTO note_source_links(id,title,url) VALUES(?,?,?)")
                try insert.run([.text(link.id.uuidString), .text(link.title), .text(link.url.absoluteString)])
                try execute("UPDATE note SET revision=revision+1 WHERE singleton=1")
            }
        }
        return link
    }

    func sourceLinks() throws -> [NoteSourceLink] {
        try lock.withLock { try readSourceLinks() }
    }

    private func readSourceLinks() throws -> [NoteSourceLink] {
        let query = try NoteStatement(db, "SELECT id,title,url FROM note_source_links ORDER BY sequence")
        var links: [NoteSourceLink] = []
        while try query.next() {
            guard let url = NoteSourceLink.httpsURL(try query.text(2)) else { throw NoteResourceError.invalidLink }
            links.append(NoteSourceLink(id: try query.uuid(0), title: try query.text(1), url: url))
        }
        return links
    }

    func searchResources(_ input: String) throws -> [NoteSearchHit] {
        let term = NoteResourceText.cleaned(NoteResourceText.bounded(input, bytes: 256))
        let key = NoteResourceText.key(term)
        guard !key.isEmpty else { return [] }
        return try lock.withLock {
            let limit = 64
            let query = try NoteStatement(db, """
                SELECT p.id,p.material_id,p.page_index,p.x0,p.x1,p.y0,p.y1,d.title,p.page_text
                FROM note_pdfs AS d JOIN note_pdf_pages AS p ON p.material_id=d.id
                WHERE instr(p.text_key,?1)>0 OR (p.page_index=0 AND instr(d.title_key,?1)>0)
                ORDER BY d.sequence,p.page_index LIMIT ?2
                """)
            try query.bind([.text(key), .integer(Int64(limit))])
            var hits: [NoteSearchHit] = []
            while try query.next() {
                let page = try pdfPage(from: query)
                hits.append(NoteSearchHit(id: page.id, title: try query.text(7),
                                          preview: NoteResourceText.preview(try query.text(8), matching: term),
                                          kind: .pdf(page)))
            }
            guard hits.count < limit else { return hits }

            for link in try readSourceLinks() where hits.count < limit &&
                NoteResourceText.key(link.title + " " + link.url.absoluteString).contains(key) {
                hits.append(NoteSearchHit(id: link.id, title: link.title, preview: link.url.absoluteString,
                                          kind: .source(link)))
            }
            guard hits.count < limit else { return hits }

            let history = try NoteStatement(db, """
                SELECT request_id,x0,x1,y0,y1,event FROM tutor_events ORDER BY sequence DESC LIMIT 24
                """)
            let decoder = JSONDecoder()
            while hits.count < limit, try history.next() {
                let event = try decoder.decode(TutorRecentEvent.self, from: history.data(5))
                guard NoteResourceText.key(event.transcript).contains(key) else { continue }
                hits.append(NoteSearchHit(id: try history.uuid(0), title: "필기 인식",
                                          preview: NoteResourceText.preview(event.transcript, matching: term),
                                          kind: .recognition(history.rect(startingAt: 1))))
            }
            return hits
        }
    }

    /// Publish a complete standalone snapshot under a new name only after SQLite finishes.
    func export(to url: URL) throws {
        try lock.withLock {
            let folder = url.deletingLastPathComponent()
            let temporary = folder.appendingPathComponent(".\(UUID().uuidString).tmp")
            defer { try? FileManager.default.removeItem(at: temporary) }
            let snapshot = try NoteStatement(db, "VACUUM INTO ?")
            try snapshot.run([.text(temporary.path)])
            try FileManager.default.moveItem(at: temporary, to: url)
        }
    }

    private static func isIndexable(_ rect: CGRect) -> Bool {
        let limit = Double(Float.greatestFiniteMagnitude) / 2
        return !rect.isNull && !rect.isInfinite && rect.size.width >= 0 && rect.size.height >= 0 &&
            [rect.minX, rect.maxX, rect.minY, rect.maxY].allSatisfy { $0.isFinite && abs($0) < limit }
    }
}
