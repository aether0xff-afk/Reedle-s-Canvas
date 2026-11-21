import SwiftUI

@MainActor
struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var document: DrawingDocument
    @StateObject private var navigation: CanvasNavigation
    @StateObject private var pdfLibrary = NotePDFLibrary()
    @StateObject private var assistant = TutorAssistant()
    @State private var tutorPanel: TutorControls.Panel?
    @State private var backup: NoteBackup?
    @State private var showingExporter = false
    @State private var backupError: String?
    private let inTutorExample: Bool
    private let openTutorExample: (() -> Void)?

    init(openTutorExample: (() -> Void)? = nil) {
        _document = StateObject(wrappedValue: DrawingDocument())
        _navigation = StateObject(wrappedValue: CanvasNavigation())
        inTutorExample = false
        self.openTutorExample = openTutorExample
    }

    init(document: DrawingDocument, navigation: CanvasNavigation, inTutorExample: Bool = false) {
        _document = StateObject(wrappedValue: document)
        _navigation = StateObject(wrappedValue: navigation)
        self.inTutorExample = inTutorExample
        openTutorExample = nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("리들의 캔버스")
                    .font(.headline)
                Spacer()
                Text("\(document.strokeCount)획")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(inTutorExample ? "tutor.exampleStrokeCount" : "canvas.strokeCount")
                HStack(spacing: 0) {
                    Button(action: document.undo) {
                        Label("실행 취소", systemImage: "arrow.uturn.backward")
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .disabled(!document.canUndo)
                    Button(action: document.redo) {
                        Label("다시 실행", systemImage: "arrow.uturn.forward")
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .disabled(!document.canRedo)
                }
                .labelStyle(.iconOnly)
                .disabled(document.loadError != nil || navigation.isUsingPencil)
                Menu("보기") {
                    Button("현재 위치 기억") { navigation.rememberPosition() }
                    Button("기억한 위치로") { navigation.returnToPosition() }
                        .disabled(navigation.bookmark == nil)
                    Divider()
                    Button("노트 백업 내보내기", action: prepareBackup)
                }
                .disabled(document.loadError != nil || navigation.isUsingPencil)
                if !inTutorExample {
                    NoteResourceControls(document: document, navigation: navigation, library: pdfLibrary)
                        .disabled(document.loadError != nil || navigation.isUsingPencil)
                    PracticeControls(document: document, navigation: navigation)
                        .disabled(document.loadError != nil || navigation.isUsingPencil)
                }
                TutorControls(document: document, assistant: assistant, panel: $tutorPanel,
                              inExample: inTutorExample, openExample: openTutorExample,
                              pencilInUse: navigation.isUsingPencil)
                    .disabled(document.loadError != nil || navigation.isUsingPencil)
                Button("저장") { document.saveNow() }
                    .disabled(document.loadError != nil)
            }
            .padding(.horizontal)
            .frame(height: 52)

            if let loadError = document.loadError {
                ContentUnavailableView(
                    "필기를 열 수 없습니다",
                    systemImage: "exclamationmark.triangle",
                    description: Text(loadError)
                )
            } else {
                ZStack {
                    Color.white
                    NotePDFCanvas(document: document, projection: navigation.projection, library: pdfLibrary)
                        .allowsHitTesting(false)
                    if let practice = document.practice.current {
                        PracticeCanvasCard(card: practice, projection: navigation.projection)
                    }
                    PencilCanvasView(document: document, navigation: navigation)
                    TutorInkCanvas(document: document, projection: navigation.projection,
                                   pencilInUse: navigation.isUsingPencil)
                    tutorNotice
                }
                .clipped()
            }
        }
        .alert("저장 실패", isPresented: $document.showSaveError) {
            Button("확인", role: .cancel) { }
        } message: {
            Text(document.saveError ?? "저장할 수 없습니다.")
        }
        .fileExporter(isPresented: $showingExporter, document: backup,
                      contentType: NoteBackup.contentType, defaultFilename: "리들의 캔버스.sqlite") { result in
            if case let .failure(error) = result {
                backupError = error.localizedDescription
            }
        }
        .onChange(of: showingExporter) { _, isPresented in
            if !isPresented { backup = nil }
        }
        .alert("백업 실패", isPresented: Binding(
            get: { backupError != nil },
            set: { if !$0 { backupError = nil } }
        )) {
            Button("확인", role: .cancel) { }
        } message: {
            Text(backupError ?? "")
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active {
                navigation.stopZoom()
                navigation.endPencilInput()
                document.endToolInteraction()
                document.saveNow()
            }
        }
    }

    @ViewBuilder
    private var tutorNotice: some View {
        if !inTutorExample, assistant.connection.enabled, document.aiLayerVisible,
           !navigation.isUsingPencil, !assistant.busy, scenePhase == .active, tutorPanel == nil {
            if let observation = assistant.latestObservation, let proposal = observation.reply.proposal,
               let anchor = observation.proposalAnchor {
                TutorCanvasNotice(projection: navigation.projection, anchor: anchor,
                                  obstacles: document.tutorNoticeObstacles, text: "판서 제안 보기") {
                    tutorPanel = .proposal(proposal)
                }
            } else if let followUp = document.tutorFollowUp, assistant.presents(followUp) {
                TutorCanvasNotice(projection: navigation.projection, anchor: followUp.anchor,
                                  obstacles: document.tutorNoticeObstacles, text: followUp.text)
            }
        }
    }

    private func prepareBackup() {
        do {
            backup = try NoteBackup(exporting: document)
            showingExporter = true
        } catch {
            backupError = error.localizedDescription
        }
    }
}
