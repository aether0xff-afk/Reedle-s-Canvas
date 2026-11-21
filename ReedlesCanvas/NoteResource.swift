import Foundation

struct NotePDFImport: Sendable {
    struct Page: Sendable {
        let size: CGSize
        let text: String
    }

    static let maximumFileBytes = 64 * 1024 * 1024
    static let maximumPages = 500
    static let maximumPageTextBytes = 16 * 1024

    let title: String
    let data: Data
    let pages: [Page]

    static func supports(_ size: CGSize) -> Bool {
        let shorter = min(size.width, size.height), longer = max(size.width, size.height)
        return size.width.isFinite && size.height.isFinite && shorter >= 1 && longer <= 14_400 &&
            longer / shorter <= 20
    }
}

struct NotePDFMaterial: Equatable, Identifiable, Sendable {
    let id: UUID
    let title: String
    let pageCount: Int
}

struct NotePDFPage: Equatable, Identifiable, Sendable {
    let id: UUID
    let materialID: UUID
    let index: Int
    let frame: CGRect
}

struct NoteSourceLink: Equatable, Identifiable, Sendable {
    let id: UUID
    let title: String
    let url: URL

    static func httpsURL(_ address: String) -> URL? {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard address.utf8.count <= 2_048, !address.isEmpty,
              !address.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              let parts = URLComponents(string: address), parts.scheme?.lowercased() == "https",
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil else { return nil }
        return parts.url
    }
}

struct NoteSearchHit: Equatable, Identifiable, Sendable {
    enum Kind: Equatable, Sendable {
        case pdf(NotePDFPage)
        case recognition(CGRect)
        case source(NoteSourceLink)
    }

    let id: UUID
    let title: String
    let preview: String
    let kind: Kind

    var frame: CGRect? {
        switch kind {
        case .pdf(let page): page.frame
        case .recognition(let frame): frame
        case .source: nil
        }
    }
}

enum NoteResourceError: LocalizedError {
    case invalidPDF, lockedPDF, fileTooLarge, tooManyPages, invalidPage
    case libraryFull, noSpace, invalidLink, noViewport, missingPDF, exportFailed

    var errorDescription: String? {
        switch self {
        case .invalidPDF: "이 PDF 파일을 열 수 없습니다."
        case .lockedPDF: "암호로 보호된 PDF는 가져올 수 없습니다."
        case .fileTooLarge: "64MB 이하의 PDF를 가져올 수 있습니다."
        case .tooManyPages: "PDF는 최대 500페이지까지 가져올 수 있습니다."
        case .invalidPage: "표시할 수 없는 크기의 PDF 페이지가 있습니다."
        case .libraryFull: "이 노트의 자료 저장 한도에 도달했습니다."
        case .noSpace: "현재 위치 근처에서 PDF를 배치할 공간을 찾을 수 없습니다."
        case .invalidLink: "유효한 HTTPS 주소를 입력하세요."
        case .noViewport: "캔버스를 연 후 다시 시도하세요."
        case .missingPDF: "이 PDF의 원본을 읽을 수 없습니다."
        case .exportFailed: "파일을 내보낼 수 없습니다."
        }
    }
}

enum NoteResourceText {
    private static let matching: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]

    static func bounded(_ text: String, bytes: Int) -> String {
        let clean = text.replacingOccurrences(of: "\0", with: "")
        guard clean.utf8.count > bytes else { return clean }
        // A split UTF-8 character can decode as one replacement character.
        return String(decoding: clean.utf8.prefix(bytes - 3), as: UTF8.self)
    }

    static func cleaned(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func key(_ text: String) -> String {
        cleaned(text).folding(options: matching, locale: Locale(identifier: "en_US_POSIX"))
    }

    static func preview(_ text: String, matching query: String) -> String {
        let text = cleaned(text)
        let match = text.range(of: query, options: matching)?.lowerBound ?? text.startIndex
        let start = text.index(match, offsetBy: -36, limitedBy: text.startIndex) ?? text.startIndex
        let snippet = text[start...].prefix(120)
        return (start == text.startIndex ? "" : "…") + snippet + (snippet.endIndex == text.endIndex ? "" : "…")
    }
}
