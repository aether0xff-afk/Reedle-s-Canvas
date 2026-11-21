import Foundation

/// Accumulate nearby edits until the next observation, favoring the newest region.
struct TutorDirtyRegion {
    private(set) var bounds: CGRect?

    mutating func record(_ next: CGRect) {
        guard !next.isEmpty, !next.isInfinite, next.minX.isFinite, next.minY.isFinite else { return }
        if let bounds, bounds.insetBy(dx: -56, dy: -56).intersects(next) {
            let union = bounds.union(next)
            if union.width <= 640, union.height <= 480 {
                self.bounds = union
                return
            }
        }
        bounds = next
    }

    func crop(in viewport: CGRect) -> CGRect? {
        guard let bounds else { return nil }
        let focus = bounds.intersection(viewport)
        guard !focus.isEmpty else { return nil }
        let width = min(640, focus.width + 400, viewport.width)
        let height = min(480, focus.height + 160, viewport.height)
        let x = min(max(focus.midX - width / 2, viewport.minX), viewport.maxX - width)
        let y = min(max(focus.midY - height / 2, viewport.minY), viewport.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    mutating func acknowledge(in crop: CGRect) {
        if bounds?.intersects(crop) == true { bounds = nil }
    }
}

enum TutorInterventionMode: String {
    case disabled, manual, automatic

    init(stored: String? = nil, enabled: Bool, automatic: Bool) {
        if let stored {
            self = Self(rawValue: stored) ?? .disabled
        } else {
            self = enabled ? (automatic ? .automatic : .manual) : .disabled
        }
    }

    func permitsRequest(manual: Bool, pendingInk: Bool) -> Bool {
        manual ? self != .disabled : self == .automatic && pendingInk
    }

    func presentsFollowUp(_ requestID: UUID, promptedBy latestRequestID: UUID?) -> Bool {
        self == .automatic || (self == .manual && requestID == latestRequestID)
    }
}

struct TutorObservationTiming {
    var pendingInk = false
    var lastAttempt: TimeInterval = -.infinity

    func delay(at now: TimeInterval, manual: Bool, mode: TutorInterventionMode, usingPencil: Bool) -> TimeInterval? {
        guard !usingPencil, mode.permitsRequest(manual: manual, pendingInk: pendingInk) else { return nil }
        return max(manual ? 0 : 1.3, 8 - (now - lastAttempt))
    }
}

struct TutorCropEntity: Codable, Equatable {
    let id: UUID
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat

    init?(id: UUID, bounds: CGRect, in crop: CGRect) {
        let overlap = bounds.intersection(crop)
        guard !overlap.isEmpty else { return nil }
        self.id = id
        x = max(0, (overlap.minX - crop.minX) / crop.width)
        y = max(0, (overlap.minY - crop.minY) / crop.height)
        width = min(1 - x, overlap.width / crop.width)
        height = min(1 - y, overlap.height / crop.height)
        guard width > 0, height > 0 else { return nil }
    }

    func worldBounds(in crop: CGRect) -> CGRect {
        CGRect(x: crop.minX + x * crop.width, y: crop.minY + y * crop.height,
               width: width * crop.width, height: height * crop.height)
    }
}

enum TutorSubject: String, Codable {
    case math, text, chemistry, physics, unknown
}

struct TutorRecentEvent: Codable, Equatable {
    let revision: Int64
    let kind: TutorSubject
    let transcript: String
    let feedback: String
    var offeredHint: Bool? = nil
    var isFollowUp: Bool? = nil  // Local presentation state, omitted from the gateway request.

    func matchesWork(kind: TutorSubject, transcript: String) -> Bool {
        guard self.kind == kind else { return false }
        func writtenForm(_ text: String) -> String {
            let normalized = text.precomposedStringWithCompatibilityMapping.filter { !$0.isWhitespace }
            guard kind == .math else { return normalized }
            return normalized.replacingOccurrences(of: "−", with: "-")
                .replacingOccurrences(of: "×", with: "*")
                .replacingOccurrences(of: "÷", with: "/")
        }
        let observed = writtenForm(transcript)
        return !observed.isEmpty && observed == writtenForm(self.transcript)
    }
}

struct TutorFollowUp: Equatable {
    let requestID: UUID
    let text: String
    let anchor: CGRect
}

struct TutorCapture: Encodable {
    static let maximumImageBytes = 512 * 1024
    static let maximumEntities = 128
    let context: TutorContext
    let crop: CGRect
    let entities: [TutorCropEntity]
    let png: Data
    let recent: [TutorRecentEvent]
    let fingerprint: Data

    init(noteID: UUID, inkRevision: Int64, crop: CGRect, entities: [TutorCropEntity], png: Data,
         recent: [TutorRecentEvent], fingerprint: Data, policyEpoch: Int64 = 0) {
        context = TutorContext(requestID: UUID(), noteID: noteID, inkRevision: inkRevision,
                               entityIDs: Set(entities.map(\.id)), policyEpoch: policyEpoch)
        self.crop = crop
        self.entities = entities
        self.png = png
        self.recent = recent
        self.fingerprint = fingerprint
    }

    private struct Bounds: Encodable {
        let x: CGFloat
        let y: CGFloat
        let width: CGFloat
        let height: CGFloat
    }

    private struct Observation: Encodable {
        let schemaVersion = 1
        let requestId: UUID
        let noteId: UUID
        let canvasRevision: Int64
        let focusBounds: Bounds
        let entityIds: [UUID]
    }

    private enum CodingKeys: String, CodingKey { case observation, image, entities, recent }

    func encode(to encoder: Encoder) throws {
        var payload = encoder.container(keyedBy: CodingKeys.self)
        let observation = Observation(requestId: context.requestID, noteId: context.noteID,
                                      canvasRevision: context.inkRevision,
                                      focusBounds: Bounds(x: crop.minX, y: crop.minY, width: crop.width, height: crop.height),
                                      entityIds: entities.map(\.id))
        try payload.encode(observation, forKey: .observation)
        try payload.encode(png, forKey: .image)
        try payload.encode(entities, forKey: .entities)
        let wireHistory = recent.map { event in
            var observation = event
            observation.isFollowUp = nil
            return observation
        }
        try payload.encode(wireHistory, forKey: .recent)
    }
}
