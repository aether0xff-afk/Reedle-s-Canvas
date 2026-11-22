import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct NoteResourceControls: View {
    let document: DrawingDocument
    let navigation: CanvasNavigation
    let library: NotePDFLibrary
    var compact = false

    @State private var showingImporter = false
    @State private var showingResources = false
    @State private var showingExporter = false
    @State private var pendingPDF: NotePDFMaterial?
    @State private var exported: NoteResourceExport?
    @State private var busy = false
    @State private var failure: String?

    var body: some View {
        Group {
            if busy {
                ProgressView()
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel("자료 처리 중")
            } else {
                Menu {
                    Button {
                        showingImporter = true
                    } label: {
                        Label("PDF 가져오기", systemImage: "doc.badge.plus")
                    }
                    Button {
                        showingResources = true
                    } label: {
                        Label("자료 및 검색", systemImage: "magnifyingglass")
                    }
                    Button {
                        prepareExport(nil)
                    } label: {
                        Label("현재 화면 이미지 내보내기", systemImage: "photo")
                    }
                } label: {
                    CanvasMenuLabel(title: "자료", systemImage: "doc.richtext", compact: compact)
                }
                .accessibilityIdentifier("resources.menu")
            }
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.pdf], onCompletion: importPDF)
        .sheet(isPresented: $showingResources, onDismiss: exportAfterClosingResources) {
            if let store = document.store {
                NoteResourcesPanel(store: store, onJump: { frame in
                    showingResources = false
                    jump(to: frame)
                }, onExport: { material in
                    pendingPDF = material
                    showingResources = false
                })
            }
        }
        .fileExporter(isPresented: $showingExporter, document: exported, contentType: exported?.contentType ?? .png,
                      defaultFilename: exported?.filename) { result in
            if case let .failure(error) = result { report(error) }
        }
        .onChange(of: showingExporter) { _, presented in if !presented { exported = nil } }
        .alert("자료 오류", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("확인", role: .cancel) { }
        } message: {
            Text(failure ?? "")
        }
    }

    private func importPDF(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            busy = true
            Task {
                defer { busy = false }
                do {
                    let source = try await Task.detached(priority: .userInitiated) {
                        try NotePDFImport.read(at: url)
                    }.value
                    guard let store = document.store, let viewport = document.currentWorldViewport else {
                        throw NoteResourceError.noViewport
                    }
                    try document.flushPendingEdits()
                    let material = try store.insertPDF(source, beside: viewport)
                    library.refreshPages()
                    if let first = try store.pdfPages(for: material.id).first { jump(to: first.frame) }
                } catch {
                    report(error)
                }
            }
        case .failure(let error):
            report(error)
        }
    }

    private func exportAfterClosingResources() {
        guard let material = pendingPDF else { return }
        pendingPDF = nil
        prepareExport(material)
    }

    private func prepareExport(_ material: NotePDFMaterial?) {
        busy = true
        Task {
            // Let a closing sheet complete presentation before opening the Files destination picker.
            await Task.yield()
            defer { busy = false }
            do {
                if let material {
                    exported = try NoteResourceExport.pdf(material, from: document)
                } else {
                    exported = try NoteResourceExport.image(from: document)
                }
                showingExporter = true
            } catch {
                report(error)
            }
        }
    }

    private func jump(to frame: CGRect) {
        guard let viewport = document.currentWorldViewport, !viewport.isEmpty, !frame.isEmpty else { return }
        let currentScale = navigation.projection.camera.scale
        let screen = CGSize(width: viewport.width * currentScale, height: viewport.height * currentScale)
        let fit = min(screen.width * 0.9 / frame.width, screen.height * 0.9 / frame.height)
        let scale = min(CanvasCamera.maximumScale, max(CanvasCamera.minimumScale, fit))
        let origin = CGPoint(x: frame.midX - screen.width / (2 * scale), y: frame.midY - screen.height / (2 * scale))
        navigation.go(to: CanvasCamera(origin: origin, scale: scale))
    }

    private func report(_ error: Error) {
        guard !(error is CancellationError), (error as? CocoaError)?.code != .userCancelled else { return }
        failure = error.localizedDescription
    }
}

@MainActor
private struct NoteResourcesPanel: View {
    let store: NoteStore
    let onJump: (CGRect) -> Void
    let onExport: (NotePDFMaterial) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var materials: [NotePDFMaterial] = []
    @State private var links: [NoteSourceLink] = []
    @State private var hits: [NoteSearchHit] = []
    @State private var searched = ""
    @State private var addingLink = false
    @State private var failure: String?

    var body: some View {
        let term = NoteResourceText.cleaned(query)
        NavigationStack {
            List {
                if term.isEmpty {
                    if materials.isEmpty && links.isEmpty {
                        ContentUnavailableView("아직 자료가 없습니다", systemImage: "doc.on.doc",
                                               description: Text("자료 메뉴에서 PDF를 가져오거나 참고 링크를 추가하세요."))
                    }
                    if !materials.isEmpty {
                        Section("PDF") {
                            ForEach(materials) { material in
                                NavigationLink {
                                    NotePDFPagesPanel(store: store, material: material, onJump: onJump, onExport: onExport)
                                } label: {
                                    row(material.title, subtitle: "\(material.pageCount)페이지", icon: "doc")
                                }
                            }
                        }
                    }
                    if !links.isEmpty {
                        Section("참고 링크") {
                            ForEach(links) { link in linkRow(link) }
                        }
                    }
                } else if searched != term {
                    ProgressView()
                } else if hits.isEmpty {
                    ContentUnavailableView.search(text: term)
                } else {
                    ForEach(hits) { hit in
                        switch hit.kind {
                        case .pdf(let page):
                            Button { onJump(page.frame) } label: {
                                row("\(hit.title) · \(page.index + 1)페이지", subtitle: hit.preview, icon: "doc")
                            }
                        case .recognition(let frame):
                            Button { onJump(frame) } label: {
                                row(hit.title, subtitle: hit.preview, icon: "pencil.line")
                            }
                        case .source(let link):
                            linkRow(link)
                        }
                    }
                }
            }
            .navigationTitle("자료")
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "PDF · 필기 · 링크 검색")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("완료") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { addingLink = true } label: { Label("링크 추가", systemImage: "link.badge.plus") }
                }
            }
            .task {
                do {
                    materials = try store.pdfMaterials()
                    links = try store.sourceLinks()
                } catch { failure = error.localizedDescription }
            }
            .task(id: [term, String(links.count)]) {
                await search(term)
            }
        }
        .sheet(isPresented: $addingLink) {
            NoteSourceLinkEditor { title, address in
                links.append(try store.insertSourceLink(title: title, address: address))
                searched = ""
            }
        }
        .alert("자료 오류", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("확인", role: .cancel) { }
        } message: {
            Text(failure ?? "")
        }
    }

    private func search(_ term: String) async {
        guard !term.isEmpty else { return }
        do {
            try await Task.sleep(for: .milliseconds(180))
            let matches = try await Task.detached(priority: .userInitiated) { [store] in
                try store.searchResources(term)
            }.value
            try Task.checkCancellation()
            hits = matches
            searched = term
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            hits = []
            searched = term
            failure = error.localizedDescription
        }
    }

    private func row(_ title: String, subtitle: String, icon: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        } icon: {
            Image(systemName: icon)
        }
    }

    private func linkRow(_ link: NoteSourceLink) -> some View {
        Link(destination: link.url) {
            row(link.title, subtitle: link.url.absoluteString, icon: "link")
        }
    }
}

@MainActor
private struct NotePDFPagesPanel: View {
    let store: NoteStore
    let material: NotePDFMaterial
    let onJump: (CGRect) -> Void
    let onExport: (NotePDFMaterial) -> Void

    @State private var pages: [NotePDFPage] = []
    @State private var failure: String?

    var body: some View {
        List(pages) { page in
            Button { onJump(page.frame) } label: { Label("\(page.index + 1)페이지", systemImage: "doc") }
        }
        .navigationTitle(material.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { onExport(material) } label: { Label("PDF 내보내기", systemImage: "square.and.arrow.up") }
                    .disabled(pages.isEmpty)
            }
        }
        .task {
            do { pages = try store.pdfPages(for: material.id) }
            catch { failure = error.localizedDescription }
        }
        .alert("PDF 오류", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("확인", role: .cancel) { }
        } message: {
            Text(failure ?? "")
        }
    }
}

@MainActor
private struct NoteSourceLinkEditor: View {
    let save: (String, String) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var address = ""
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("제목 (선택)", text: $title)
                TextField("https://", text: $address)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .navigationTitle("참고 링크 추가")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("추가") {
                        do {
                            try save(title, address)
                            dismiss()
                        } catch { failure = error.localizedDescription }
                    }
                    .disabled(NoteSourceLink.httpsURL(address) == nil)
                }
            }
            .alert("링크 오류", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("확인", role: .cancel) { }
            } message: {
                Text(failure ?? "")
            }
        }
    }
}
