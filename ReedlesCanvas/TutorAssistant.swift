import Foundation
import Security
import SwiftUI

struct TutorConnection {
    var server = ""
    var token = ""
    var enabled = false
    var automatic = false
    var sensitivity: TutorSensitivity = .standard

    var mode: TutorInterventionMode {
        get { TutorInterventionMode(enabled: enabled, automatic: automatic) }
        set {
            enabled = newValue != .disabled
            automatic = newValue == .automatic
        }
    }

    var endpoint: URL? {
        guard enabled, TutorGateway.isAccessToken(token) else { return nil }
        return try? TutorGateway.observationEndpoint(server)
    }

    private static let keychain: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "dev.aether.reedlescanvas.tutor",
        kSecAttrAccount as String: "access"
    ]

    static func load() -> TutorConnection {
        var query = keychain
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        let token = status == errSecSuccess ? (result as? Data).flatMap { String(data: $0, encoding: .utf8) } : nil
        let defaults = UserDefaults.standard
        let mode = TutorInterventionMode(stored: defaults.string(forKey: "tutorMode"),
                                         enabled: defaults.bool(forKey: "tutorEnabled"),
                                         automatic: defaults.bool(forKey: "tutorAutomatic"))
        return TutorConnection(server: defaults.string(forKey: "tutorServer") ?? "", token: token ?? "",
                               enabled: mode != .disabled, automatic: mode == .automatic,
                               sensitivity: TutorSensitivity(rawValue: defaults.string(forKey: "tutorSensitivity") ?? "") ?? .standard)
    }

    func save() throws {
        if enabled, endpoint == nil { throw TutorGatewayError.invalidConnection }
        if token.isEmpty {
            let status = SecItemDelete(Self.keychain as CFDictionary)
            guard status == errSecItemNotFound || status == errSecSuccess else { throw TutorGatewayError.invalidConnection }
        } else {
            let data = Data(token.utf8)
            let updated = SecItemUpdate(Self.keychain as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if updated == errSecItemNotFound {
                var insert = Self.keychain
                insert[kSecValueData as String] = data
                insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else {
                    throw TutorGatewayError.invalidConnection
                }
            } else if updated != errSecSuccess {
                throw TutorGatewayError.invalidConnection
            }
        }
        let defaults = UserDefaults.standard
        defaults.set(server, forKey: "tutorServer")
        saveMode()
        defaults.set(sensitivity.rawValue, forKey: "tutorSensitivity")
    }

    func saveMode() {
        UserDefaults.standard.set(mode.rawValue, forKey: "tutorMode")
    }
}

@MainActor
final class TutorAssistant: ObservableObject {
    @Published private(set) var connection = TutorConnection.load()
    @Published private(set) var latestObservation: (requestID: UUID, reply: TutorGatewayReply, proposalAnchor: CGRect?)?
    @Published private(set) var status: String?
    @Published private(set) var busy = false
    @Published private(set) var progress: TutorStreamPhase?

    private let requestTask = TutorRequestTask()
    private var timing = TutorObservationTiming()
    private var fingerprint: Data?
    private var retryWindow = TutorRetryWindow()
    private var retryMessage: String?

    var latest: TutorGatewayReply? { latestObservation?.reply }

    func presents(_ followUp: TutorFollowUp) -> Bool {
        connection.mode.presentsFollowUp(followUp.requestID, promptedBy: latestObservation?.requestID)
    }

    func setMode(_ mode: TutorInterventionMode, in document: DrawingDocument) {
        guard mode != connection.mode else { return }
        clearObservation()
        document.resetTutorFocus()
        var edited = connection
        edited.mode = mode
        edited.saveMode()
        connection = edited
    }

    func updateConnection(_ edited: TutorConnection, in document: DrawingDocument) throws {
        try edited.save()
        clearObservation()
        document.resetTutorFocus()
        retryWindow = TutorRetryWindow()
        retryMessage = nil
        connection = edited
    }

    func inkChanged(in document: DrawingDocument, ready: Bool) {
        timing.pendingInk = connection.mode == .automatic
        dismissReply()
        stop()
        if ready { request(in: document, manual: false) }
    }

    func request(in document: DrawingDocument, manual: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        guard let endpoint = connection.endpoint,
              let delay = timing.delay(at: now, manual: manual, mode: connection.mode,
                                       usingPencil: document.toolActive) else { return }
        guard now >= retryWindow.notBefore else {
            if manual { status = retryMessage }
            return
        }
        stop()
        busy = true
        let token = connection.token
        let sensitivity = manual ? TutorSensitivity.standard : connection.sensitivity
        requestTask.start { [weak self, weak document] issued in
            guard let self, let document else { return }
            defer { if self.requestTask.id == issued { self.stop(clearStatus: false) } }
            do {
                try await Task.sleep(for: .seconds(delay))
                try Task.checkCancellation()
                self.timing.pendingInk = false
                guard let capture = try document.captureForTutor(manual: manual) else {
                    if manual { self.status = "화면에 보이는 필기가 필요합니다." }
                    return
                }
                if !manual, capture.fingerprint == self.fingerprint {
                    try document.finishTutorObservation(capture)
                    return
                }
                self.timing.lastAttempt = ProcessInfo.processInfo.systemUptime
                let received = try await TutorGateway.observe(capture, endpoint: endpoint, accessToken: token) { phase in
                    if !Task.isCancelled, self.requestTask.id == issued { self.progress = phase }
                }
                try Task.checkCancellation()
                guard self.requestTask.id == issued else { return }
                self.retryWindow = TutorRetryWindow()
                self.retryMessage = nil
                let reply = received.applying(sensitivity)
                try document.finishTutorObservation(capture, reply: reply, sensitivity: sensitivity)
                self.fingerprint = capture.fingerprint
                self.latestObservation = (capture.context.requestID, reply, reply.proposalAnchor(in: capture))
            } catch TutorProposalError.stale {
                // A newer Pencil edit takes priority over this reply.
            } catch {
                guard !Task.isCancelled, self.requestTask.id == issued else { return }
                self.reportNetworkFailure(error)
            }
        }
    }

    private func reportNetworkFailure(_ error: Error) {
        let now = ProcessInfo.processInfo.systemUptime
        let message: String
        switch error {
        case TutorGatewayError.unauthorized:
            retryWindow.requireNewCredentials()
            message = "튜터 서버 접속 토큰을 확인해 주세요."
        case TutorGatewayError.limit(let delay):
            retryWindow.recordFailure(at: now, retryAfter: delay)
            message = "현재 튜터 요청 한도에 도달했습니다."
        case TutorGatewayError.unavailable(let delay):
            retryWindow.recordFailure(at: now, retryAfter: delay)
            message = "튜터 서버가 잠시 응답할 수 없습니다. 필기는 계속할 수 있습니다."
        default:
            retryWindow.recordFailure(at: now)
            message = "튜터 요청을 마칠 수 없습니다. 필기는 계속할 수 있습니다."
        }
        retryMessage = message
        status = message
    }

    func stop(clearStatus: Bool = true) {
        requestTask.cancel()
        busy = false
        if progress != nil { progress = nil }
        if clearStatus { status = nil }
    }

    func dismissReply() {
        if latestObservation != nil { latestObservation = nil }
    }

    func cancelRequest() {
        timing.pendingInk = false
        stop()
    }

    func clearObservation() {
        cancelRequest()
        fingerprint = nil
        dismissReply()
    }
}
