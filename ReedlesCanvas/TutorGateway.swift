import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct TutorRecognition: Codable, Equatable {
    let kind: TutorSubject
    let transcript: String
    let confidence: Double
    let targetEntityIds: [UUID]

    var isConfident: Bool { kind != .unknown && confidence >= 0.82 }
}

struct TutorGatewayReply {
    let recognition: TutorRecognition
    let reason: String
    let proposal: TutorProposal?

    func applying(_ sensitivity: TutorSensitivity) -> Self {
        guard recognition.confidence < sensitivity.threshold, proposal != nil else { return self }
        return Self(recognition: recognition, reason: "확신도가 높아질 때까지 자동 제안을 보류했습니다.", proposal: nil)
    }

    func proposalAnchor(in capture: TutorCapture) -> CGRect? {
        guard let target = proposal?.actions.first?.targetID else { return nil }
        return capture.entities.first(where: { $0.id == target })?.worldBounds(in: capture.crop)
    }

    func historyEntry(for capture: TutorCapture, sensitivity: TutorSensitivity) -> (event: TutorRecentEvent, bounds: CGRect)? {
        guard recognition.isConfident else { return nil }
        let targets = Set(recognition.targetEntityIds)
        let bounds = capture.entities.filter { targets.contains($0.id) }
            .reduce(CGRect.null) { $0.union($1.worldBounds(in: capture.crop)) }
        guard !bounds.isEmpty else { return nil }
        let previous = capture.recent.max { $0.revision < $1.revision }
        let followsHint = previous?.offeredHint == true && previous?.kind == recognition.kind
        let sameWork = previous?.matchesWork(kind: recognition.kind, transcript: recognition.transcript) == true
        let followUp = proposal == nil && followsHint && !sameWork && recognition.confidence >= sensitivity.threshold
            && !recognition.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let event = TutorRecentEvent(revision: capture.context.inkRevision, kind: recognition.kind,
                                     transcript: recognition.transcript, feedback: reason,
                                     offeredHint: proposal != nil || (followsHint && sameWork),
                                     isFollowUp: followUp ? true : nil)
        return (event, bounds)
    }

    private struct Metadata: Decodable {
        let model: String
        let reason: String
        let recognition: TutorRecognition
    }

    static func decode(_ data: Data, context: TutorContext) throws -> Self {
        guard data.count <= 96 * 1024,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["model", "reason", "recognition", "response"],
              let raw = object["response"] as? [String: Any] else { throw TutorGatewayError.invalidResult }
        let envelope = try JSONDecoder().decode(Metadata.self, from: data)
        let recognition = envelope.recognition
        let targets = Set(recognition.targetEntityIds)
        guard (0...1).contains(recognition.confidence), recognition.transcript.utf8.count <= 1_024,
              recognition.targetEntityIds.count == targets.count, targets.isSubset(of: context.entityIDs) else {
            throw TutorGatewayError.invalidResult
        }
        let proposal = try TutorProposal.decode(JSONSerialization.data(withJSONObject: raw), for: context,
                                                 model: envelope.model, reason: envelope.reason)
        if let proposal, recognition.isConfident,
           !Set(proposal.actions.map(\.targetID)).isSubset(of: targets) { throw TutorGatewayError.invalidResult }
        return Self(recognition: recognition, reason: envelope.reason, proposal: recognition.isConfident ? proposal : nil)
    }
}

enum TutorSensitivity: String, CaseIterable {
    case standard, reserved, cautious

    var threshold: Double {
        switch self {
        case .standard: return 0.82
        case .reserved: return 0.90
        case .cautious: return 0.96
        }
    }

    var title: String {
        switch self {
        case .standard: return "기본"
        case .reserved: return "낮음"
        case .cautious: return "아주 낮음"
        }
    }
}

enum TutorGatewayError: Error {
    case invalidConnection, invalidResult, unauthorized
    case limit(retryAfter: TimeInterval?)
    case unavailable(retryAfter: TimeInterval?)
}

enum TutorStreamPhase: String, Decodable, Sendable {
    case reading, drafting
}

@MainActor
final class TutorRequestTask {
    private(set) var id: UUID?
    private var task: Task<Void, Never>?

    @discardableResult
    func start(_ operation: @escaping @MainActor (UUID) async -> Void) -> Task<Void, Never> {
        cancel()
        let id = UUID()
        self.id = id
        let running = Task {
            guard !Task.isCancelled else { return }
            await operation(id)
        }
        task = running
        return running
    }

    func cancel() {
        id = nil
        task?.cancel()
        task = nil
    }
}

struct TutorRetryWindow {
    private(set) var notBefore: TimeInterval = 0
    private var failures = 0

    mutating func recordFailure(at now: TimeInterval, retryAfter: TimeInterval? = nil) {
        let intervals: [TimeInterval] = [8, 16, 32, 60]
        let delay = max(intervals[failures], retryAfter ?? 0)
        failures = min(failures + 1, intervals.count - 1)
        notBefore = max(notBefore, now + delay)
    }

    mutating func requireNewCredentials() { notBefore = .infinity }
}

enum TutorGateway {
    private class RejectRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private static let session = URLSession(configuration: configuration(), delegate: RejectRedirects(), delegateQueue: nil)

    private static func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 35
        config.timeoutIntervalForResource = 42
        config.urlCache = nil
        return config
    }

    static func observationEndpoint(_ server: String) throws -> URL {
        guard let address = URLComponents(string: server.trimmingCharacters(in: .whitespacesAndNewlines)),
              address.scheme?.lowercased() == "https", let host = address.host, !host.isEmpty,
              address.user == nil, address.password == nil, address.query == nil, address.fragment == nil,
              let base = address.url else { throw TutorGatewayError.invalidConnection }
        return base.appendingPathComponent("v1").appendingPathComponent("tutor").appendingPathComponent("observe")
    }

    static func isAccessToken(_ token: String) -> Bool {
        !token.isEmpty && token.utf8.count <= 512 && token.utf8.allSatisfy { (33...126).contains($0) }
    }

    static func retryDelay(_ header: String?) -> TimeInterval? {
        guard let header, let seconds = Int(header.trimmingCharacters(in: .whitespaces)), seconds >= 0 else { return nil }
        return TimeInterval(min(seconds, 86_400))
    }

    static func observe(_ capture: TutorCapture, endpoint: URL, accessToken: String,
                        onProgress: (@MainActor (TutorStreamPhase) -> Void)? = nil) async throws -> TutorGatewayReply {
        guard isAccessToken(accessToken) else { throw TutorGatewayError.invalidConnection }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(capture)
        if let onProgress {
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            return try await observeStream(request, context: capture.context, onProgress: onProgress)
        }
        let (bytes, reply) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = reply as? HTTPURLResponse else { throw TutorGatewayError.invalidResult }
        if http.statusCode != 200 { throw failure(http.statusCode, retryAfter: httpRetryDelay(http)) }
        return try TutorGatewayReply.decode(bytes, context: capture.context)
    }

    private static func httpRetryDelay(_ response: HTTPURLResponse) -> TimeInterval? {
        retryDelay(response.value(forHTTPHeaderField: "Retry-After"))
    }

    private static func failure(_ status: Int, retryAfter: TimeInterval?) -> TutorGatewayError {
        switch status {
        case 401, 403: return .unauthorized
        case 429: return .limit(retryAfter: retryAfter)
        default: return .unavailable(retryAfter: retryAfter)
        }
    }

    private enum StreamMessage: Sendable {
        case progress(TutorStreamPhase)
        case result(Data)
    }

    private static func observeStream(_ request: URLRequest, context: TutorContext,
                                      onProgress: @MainActor (TutorStreamPhase) -> Void) async throws -> TutorGatewayReply {
        let (messages, continuation) = AsyncThrowingStream<StreamMessage, Error>.makeStream(bufferingPolicy: .bufferingOldest(4))
        let transport = URLSession(configuration: configuration(), delegate: ObservationDelegate(continuation), delegateQueue: nil)
        defer { transport.invalidateAndCancel() }
        try Task.checkCancellation()
        transport.dataTask(with: request).resume()
        for try await message in messages {
            try Task.checkCancellation()
            switch message {
            case .progress(let phase): await onProgress(phase)
            case .result(let data): return try TutorGatewayReply.decode(data, context: context)
            }
        }
        try Task.checkCancellation()
        throw TutorGatewayError.invalidResult
    }

    // URLSession delivers the delegate callbacks on its serial queue. Only complete messages cross to the caller.
    private final class ObservationDelegate: RejectRedirects, URLSessionDataDelegate, @unchecked Sendable {
        private struct Progress: Decodable { let phase: TutorStreamPhase }
        private struct Problem: Decodable {
            let status: Int
            let retryAfter: Int?
        }

        private let continuation: AsyncThrowingStream<StreamMessage, Error>.Continuation
        private var buffer = Data()
        private var receivedBytes = 0
        private var isEventStream = false
        private var finished = false
        private var phase: TutorStreamPhase?
        private var name: String?
        private var payload: Data?

        init(_ continuation: AsyncThrowingStream<StreamMessage, Error>.Continuation) {
            self.continuation = continuation
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            guard let http = response as? HTTPURLResponse else {
                finish(TutorGatewayError.invalidResult)
                completionHandler(.cancel)
                return
            }
            guard http.statusCode == 200 else {
                finish(failure(http.statusCode, retryAfter: httpRetryDelay(http)))
                completionHandler(.cancel)
                return
            }
            isEventStream = http.mimeType?.lowercased() == "text/event-stream"
            guard isEventStream || http.mimeType?.lowercased() == "application/json" else {
                finish(TutorGatewayError.invalidResult)
                completionHandler(.cancel)
                return
            }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            guard !finished else { return }
            receivedBytes += data.count
            guard receivedBytes <= 128 * 1024 else {
                finish(TutorGatewayError.invalidResult)
                dataTask.cancel()
                return
            }
            buffer.append(data)
            guard isEventStream else { return }
            do {
                while !finished, let end = buffer.firstIndex(of: 10) {
                    var line = buffer[..<end]
                    buffer.removeSubrange(...end)
                    if line.last == 13 { line.removeLast() }
                    try consume(line)
                }
            } catch {
                finish(error)
                dataTask.cancel()
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard !finished else { return }
            if let error {
                finish(error)
            } else if isEventStream {
                finish(TutorGatewayError.invalidResult)
            } else {
                continuation.yield(.result(buffer))
                finish()
            }
        }

        private func consume(_ line: Data) throws {
            if line.first == 58 { return }  // SSE heartbeat comment.
            if line.isEmpty {
                guard name != nil || payload != nil else { return }
                guard let name, let payload else { throw TutorGatewayError.invalidResult }
                self.name = nil
                self.payload = nil
                let decoder = JSONDecoder()
                switch name {
                case "progress":
                    let next = try decoder.decode(Progress.self, from: payload).phase
                    guard (phase == nil && next == .reading) || (phase == .reading && next == .drafting) else {
                        throw TutorGatewayError.invalidResult
                    }
                    phase = next
                    continuation.yield(.progress(next))
                case "result":
                    continuation.yield(.result(payload))
                    finish()
                case "error":
                    let problem = try decoder.decode(Problem.self, from: payload)
                    let delay = problem.retryAfter.map { TimeInterval(max(0, min($0, 86_400))) }
                    finish(failure(problem.status, retryAfter: delay))
                default: throw TutorGatewayError.invalidResult
                }
            } else if name == nil, line.starts(with: "event: ".utf8) {
                name = String(decoding: line.dropFirst(7), as: UTF8.self)
            } else if name != nil, payload == nil, line.starts(with: "data: ".utf8) {
                payload = Data(line.dropFirst(6))
            } else {
                throw TutorGatewayError.invalidResult
            }
        }

        private func finish(_ error: Error? = nil) {
            finished = true
            continuation.finish(throwing: error)
        }
    }
}
