import SwiftUI
import UniformTypeIdentifiers

struct NoteBackup: FileDocument {
    static let contentType = UTType(filenameExtension: "sqlite", conformingTo: .data) ?? .data
    static var readableContentTypes: [UTType] { [contentType] }

    private let data: Data

    @MainActor
    init(exporting document: DrawingDocument) throws {
        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: directory) }

        let url = directory.appendingPathComponent("note.sqlite")
        try document.exportBackup(to: url)
        // The immutable snapshot (including a file mapping when supported) survives unlink.
        data = try Data(contentsOf: url, options: .mappedIfSafe)
    }

    init(configuration: ReadConfiguration) throws {
        guard let contents = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        data = contents
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
