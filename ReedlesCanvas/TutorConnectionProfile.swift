import Foundation

enum TutorConnectionProfileError: LocalizedError {
    case invalid, tooLarge, providerCredential

    var errorDescription: String? {
        switch self {
        case .invalid: return "지원되는 튜터 연결 파일이 아닙니다. 서버에서 내보낸 JSON 파일을 선택해 주세요."
        case .tooLarge: return "연결 파일은 8KB 이하여야 합니다."
        case .providerCredential: return "BAZE API 키는 서버에서만 사용합니다. 별도의 앱 접속 토큰이 담긴 연결 파일을 선택해 주세요."
        }
    }
}

struct TutorConnectionProfile: Decodable, Sendable {
    static let maximumBytes = 8_192
    let server: String
    let accessToken: String

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case format, version, server
        case accessToken = "access_token"
    }
    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.container(keyedBy: Key.self)
        let names = Set(raw.allKeys.map(\.stringValue))
        if !names.isDisjoint(with: ["api_key", "baze_api_key", "provider_key"]) {
            throw TutorConnectionProfileError.providerCredential
        }
        guard names == Set(CodingKeys.allCases.map(\.rawValue)) else { throw TutorConnectionProfileError.invalid }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(String.self, forKey: .format) == "reedle.tutor.connection",
              try values.decode(Int.self, forKey: .version) == 1 else { throw TutorConnectionProfileError.invalid }
        let address = try values.decode(String.self, forKey: .server).trimmingCharacters(in: .whitespacesAndNewlines)
        let token = try values.decode(String.self, forKey: .accessToken)
        guard address.utf8.count <= 2_048, TutorGateway.isAccessToken(token) else { throw TutorConnectionProfileError.invalid }
        guard !token.lowercased().hasPrefix("baze_") else { throw TutorConnectionProfileError.providerCredential }
        _ = try TutorGateway.observationEndpoint(address)
        server = address
        accessToken = token
    }

    static func read(from url: URL) throws -> Self {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw TutorConnectionProfileError.tooLarge }
        guard !data.isEmpty else { throw TutorConnectionProfileError.invalid }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    func applying(to current: TutorConnection) -> TutorConnection {
        var draft = current
        draft.server = server
        draft.token = accessToken
        draft.enabled = false
        draft.automatic = false
        return draft
    }
}
