import Foundation

enum TutorPlacementIntent: String, Codable {
    case nearRight = "near_right"
    case nearLeft = "near_left"
    case above, below
    case onTarget = "on_target"
}

enum TutorDrawing: String, Codable {
    case arrow, underline, circle
    case triangle = "diagram:triangle"
    case rectangle = "diagram:rectangle"
    case line = "plot:line"
    case parabola = "plot:parabola"
    case sine = "plot:sine"
}

enum TutorInk: Equatable {
    case text(String)
    case math(TutorFormula)
    case drawing(TutorDrawing)
}

struct TutorAction: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case annotate, write, draw, askQuestion = "ask_question" }

    let id: UUID
    let kind: Kind
    let targetID: UUID
    let intent: TutorPlacementIntent
    let content: String

    private enum CodingKeys: String, CodingKey {
        case id = "actionId"
        case kind = "type"
        case targetID = "targetEntityId"
        case intent = "placementIntent"
        case content
    }

    var ink: TutorInk? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, content.unicodeScalars.count <= 2_000,
              !trimmed.unicodeScalars.contains(where: {
                  $0 != "\n" && CharacterSet.controlCharacters.contains($0)
              }) else { return nil }
        if kind == .draw { return TutorDrawing(rawValue: content).map(TutorInk.drawing) }
        guard kind == .write else { return .text(trimmed) }
        let formula = TutorFormula(trimmed)
        return formula.isStructured ? .math(formula) : .text(formula.plainText)
    }
}

struct TutorContext: Equatable {
    let requestID: UUID
    let noteID: UUID
    let inkRevision: Int64
    let entityIDs: Set<UUID>
    let policyEpoch: Int64

    init(requestID: UUID, noteID: UUID, inkRevision: Int64, entityIDs: Set<UUID>, policyEpoch: Int64 = 0) {
        self.requestID = requestID
        self.noteID = noteID
        self.inkRevision = inkRevision
        self.entityIDs = entityIDs
        self.policyEpoch = policyEpoch
    }
}

struct TutorResponse: Codable {
    enum Decision: String, Codable { case observeOnly = "observe_only", act }

    let schemaVersion: Int
    let requestID: UUID
    let noteID: UUID
    let observedRevision: Int64
    let decision: Decision
    let actions: [TutorAction]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, requestID = "requestId", noteID = "noteId", observedRevision, decision, actions
    }
}

enum TutorProposalError: Error {
    case invalidResponse, stale, missingAnchor
}

/// Only a validated response bound to an observation can reach the annotation store.
struct TutorProposal: Identifiable {
    let context: TutorContext
    let model: String
    let reason: String
    let actions: [TutorAction]
    var id: UUID { context.requestID }

    private init(context: TutorContext, model: String, reason: String, actions: [TutorAction]) {
        self.context = context
        self.model = model
        self.reason = reason
        self.actions = actions
    }

    static func decode(_ bytes: Data, for context: TutorContext, model: String, reason: String) throws -> Self? {
        let responseKeys: Set = ["schemaVersion", "requestId", "noteId", "observedRevision", "decision", "actions"]
        let actionKeys: Set = ["actionId", "type", "targetEntityId", "placementIntent", "content"]
        guard bytes.count <= 64 * 1024, !model.isEmpty, model.utf8.count <= 128, reason.utf8.count <= 512,
              let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              Set(object.keys) == responseKeys, let rawActions = object["actions"] as? [[String: Any]],
              rawActions.count <= 4, rawActions.allSatisfy({ Set($0.keys) == actionKeys }) else {
            throw TutorProposalError.invalidResponse
        }
        let response = try JSONDecoder().decode(TutorResponse.self, from: bytes)
        guard response.schemaVersion == 1, response.observedRevision >= 0 else {
            throw TutorProposalError.invalidResponse
        }
        guard response.requestID == context.requestID, response.noteID == context.noteID,
              response.observedRevision == context.inkRevision else { throw TutorProposalError.stale }
        if response.decision == .observeOnly {
            guard response.actions.isEmpty else { throw TutorProposalError.invalidResponse }
            return nil
        }
        guard !response.actions.isEmpty, Set(response.actions.map(\.id)).count == response.actions.count,
              response.actions.allSatisfy({ $0.ink != nil }) else { throw TutorProposalError.invalidResponse }
        guard response.actions.allSatisfy({ context.entityIDs.contains($0.targetID) }) else {
            throw TutorProposalError.missingAnchor
        }
        return Self(context: context, model: model, reason: reason, actions: response.actions)
    }
}

struct TutorAnnotation: Equatable, Identifiable {
    let requestID: UUID
    let inkRevision: Int64
    let model: String
    let reason: String
    let version: Int64
    let action: TutorAction
    var id: UUID { action.id }
}
