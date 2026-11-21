import PencilKit
import SwiftUI

@MainActor
struct TutorControls: View {
    @ObservedObject var document: DrawingDocument
    @ObservedObject var assistant: TutorAssistant
    @Binding var panel: Panel?
    let inExample: Bool
    let openExample: (() -> Void)?
    let pencilInUse: Bool
    @Environment(\.scenePhase) private var scenePhase
    @State private var approval: TutorProposal?
    @State private var errorText: String?
    @State private var confirmingErase = false
    @State private var savedRecognition: [TutorRecentEvent] = []

    enum Panel: Identifiable {
        case annotations, proposal(TutorProposal), connection, recognition, history
        var id: String {
            switch self {
            case .annotations: return "annotations"
            case .connection: return "connection"
            case .recognition: return "recognition"
            case .history: return "history"
            case .proposal(let proposal): return proposal.id.uuidString
            }
        }
    }

    private var menuTitle: String {
        switch assistant.progress {
        case .reading: return "필기 읽는 중…"
        case .drafting: return "답변 작성 중…"
        case nil:
            if assistant.latest?.proposal != nil { return "튜터 제안" }
            if visibleFollowUp != nil { return "튜터 피드백" }
            return "튜터"
        }
    }

    private var visibleFollowUp: TutorFollowUp? {
        guard document.aiLayerVisible, let feedback = document.tutorFollowUp, assistant.presents(feedback) else { return nil }
        return feedback
    }

    var body: some View {
        Menu(menuTitle) {
            if inExample {
                Button("예제 답변 보기", action: showExampleProposal)
                    .accessibilityIdentifier("tutor.exampleReply")
            } else if let openExample {
                if assistant.connection.endpoint != nil {
                    Button("이 영역 질문하기") { assistant.request(in: document, manual: true) }
                        .disabled(assistant.busy)
                }
                if assistant.busy {
                    Button("튜터 요청 중단", action: assistant.cancelRequest)
                }
                if assistant.connection.mode != .disabled {
                    Toggle("조용히 모드", isOn: Binding(get: { assistant.connection.mode == .manual }, set: { quiet in
                        assistant.setMode(quiet ? .manual : .automatic, in: document)
                    }))
                    .accessibilityHint("직접 질문할 때만 필기를 보냅니다.")
                    .accessibilityIdentifier("tutor.quietMode")
                    Button("튜터 사용 중지") { assistant.setMode(.disabled, in: document) }
                        .accessibilityHint("진행 중인 요청을 중단하고 새 전송을 막습니다.")
                        .accessibilityIdentifier("tutor.disable")
                }
                if assistant.latest != nil || visibleFollowUp != nil {
                    Button("최근 인식 결과") { panel = .recognition }
                    if let proposal = assistant.latest?.proposal {
                        Button("새 판서 제안 보기") { panel = .proposal(proposal) }
                    }
                }
                if let status = assistant.status { Text(status) }
                Button("튜터 연결 설정") { panel = .connection }
                Button("판서 예제 열기", action: openExample)
                    .accessibilityIdentifier("tutor.openExample")
            }
            Toggle("튜터 판서 표시", isOn: Binding(get: { document.aiLayerVisible },
                                                 set: document.setAILayerVisible))
            Button("현재 영역의 판서") { panel = .annotations }
                .disabled(document.tutorAnnotations.isEmpty)
                .accessibilityIdentifier("tutor.annotations")
            Button("마지막 튜터 판서 되돌리기", action: undo)
                .disabled(!document.canUndoTutor)
                .accessibilityIdentifier("tutor.undo")
            Button("이 노트의 인식 기록", action: showHistory)
            Button("튜터 기록 삭제", role: .destructive) { confirmingErase = true }
        }
        .accessibilityIdentifier(inExample ? "tutor.exampleMenu" : "tutor.menu")
        .sheet(item: $panel, onDismiss: applyApproval) { panel in
            switch panel {
            case .connection:
                TutorConnectionEditor(connection: assistant.connection) { edited in
                    try assistant.updateConnection(edited, in: document)
                }
            case .recognition:
                NavigationStack {
                    List {
                        if let latest = assistant.latest {
                            Text(latest.recognition.transcript.isEmpty ? "읽을 수 있는 필기를 찾지 못했습니다."
                                                                     : latest.recognition.transcript)
                            if !latest.recognition.isConfident {
                                Text("인식이 불확실해 판서 제안을 만들지 않았습니다.")
                                    .foregroundStyle(.secondary)
                            } else if !latest.reason.isEmpty {
                                Text(latest.reason)
                            }
                        } else if let followUp = visibleFollowUp {
                            Text(verbatim: followUp.text)
                        }
                    }
                    .navigationTitle("최근 인식 결과")
                    .toolbar { Button("닫기") { self.panel = nil } }
                }
            case .history:
                NavigationStack {
                    Group {
                        if savedRecognition.isEmpty {
                            ContentUnavailableView("저장된 인식 기록이 없습니다", systemImage: "text.magnifyingglass")
                        } else {
                            List(savedRecognition.indices, id: \.self) { index in
                                let event = savedRecognition[index]
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(event.transcript)
                                    if !event.feedback.isEmpty {
                                        Text(event.feedback).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    .navigationTitle("인식 기록")
                    .toolbar { Button("닫기") { self.panel = nil } }
                }
            case .annotations:
                NavigationStack {
                    List(document.tutorAnnotations) { annotation in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(actionLabel(annotation.action))
                            Text(annotation.reason.isEmpty ? annotation.model : annotation.reason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .navigationTitle("현재 영역의 판서")
                    .toolbar {
                        Button("닫기") { self.panel = nil }
                            .accessibilityIdentifier("tutor.closeAnnotations")
                    }
                }
            case .proposal(let proposal):
                NavigationStack {
                    List(proposal.actions) { action in Text(actionLabel(action)) }
                        .navigationTitle(proposal.model)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("취소") {
                                    if assistant.latest?.proposal?.id == proposal.id { assistant.dismissReply() }
                                    self.panel = nil
                                }
                                    .accessibilityIdentifier("tutor.cancel")
                            }
                            ToolbarItem(placement: .confirmationAction) {
                                Button("판서 적용") {
                                    approval = proposal
                                    self.panel = nil
                                }
                                .accessibilityIdentifier("tutor.apply")
                            }
                        }
                }
            }
        }
        .alert("튜터 판서", isPresented: Binding(get: { errorText != nil },
                                               set: { if !$0 { errorText = nil } })) {
            Button("확인", role: .cancel) { }
        } message: {
            Text(errorText ?? "")
        }
        .confirmationDialog("튜터 기록을 삭제할까요?", isPresented: $confirmingErase, titleVisibility: .visible) {
            Button("삭제", role: .destructive, action: eraseHistory)
            Button("취소", role: .cancel) { }
        } message: {
            Text("현재 노트의 튜터 판서와 인식 기록을 지웁니다. 이전에 만든 백업은 저장한 위치에서 관리할 수 있습니다. 서버에 전송된 내용은 각 서비스의 보관 정책을 따릅니다.")
        }
        .onChange(of: document.inkActivity) { _, _ in
            guard openExample != nil else { return }
            assistant.inkChanged(in: document, ready: !pencilInUse && scenePhase == .active)
        }
        .onChange(of: pencilInUse) { _, inUse in
            guard openExample != nil else { return }
            if inUse { assistant.stop() }
            else if scenePhase == .active { assistant.request(in: document, manual: false) }
        }
        .onChange(of: scenePhase) { _, next in
            if next != .active { assistant.stop() }
        }
        .onDisappear { assistant.stop() }
    }

    private func actionLabel(_ action: TutorAction) -> String {
        switch action.ink {
        case .text(let text): return text
        case .math(let formula): return formula.plainText
        case .drawing(.circle): return "답에 테두리 표시"
        case .drawing(.underline): return "대상 밑줄"
        case .drawing(.arrow): return "대상을 가리키는 화살표"
        case .drawing(.triangle): return "삼각형"
        case .drawing(.rectangle): return "사각형"
        case .drawing(.line): return "직선 그래프"
        case .drawing(.parabola): return "포물선 그래프"
        case .drawing(.sine): return "사인 그래프"
        case nil: return action.content
        }
    }

    private func showExampleProposal() {
        do {
            let next = try TutorExample.proposal(in: document)
            panel = .proposal(next)
        } catch {
            errorText = "예제의 마지막 숫자가 보이는 곳에서 열어 주세요."
        }
    }

    private func applyApproval() {
        guard let approval else { return }
        self.approval = nil
        do {
            try document.approveTutorProposal(approval)
            if assistant.latest?.proposal?.id == approval.id { assistant.dismissReply() }
        } catch TutorProposalError.stale {
            errorText = "제안을 받은 뒤 필기가 바뀌었습니다. 새 제안을 열어 주세요."
        } catch {
            errorText = "튜터 판서를 저장할 수 없습니다."
        }
    }

    private func undo() {
        do { try document.undoTutor() }
        catch { errorText = "튜터 판서를 되돌릴 수 없습니다." }
    }

    private func showHistory() {
        do {
            savedRecognition = try document.tutorHistoryForReading()
            panel = .history
        } catch { errorText = "인식 기록을 열 수 없습니다." }
    }

    private func eraseHistory() {
        assistant.clearObservation()
        do {
            try document.eraseTutorData()
            savedRecognition = []
        } catch { errorText = "튜터 기록을 삭제할 수 없습니다." }
    }
}

@MainActor
private struct TutorConnectionEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var connection: TutorConnection
    @State private var invalid = false
    @State private var letterSize = TutorLetterSize.saved
    @State private var inkColor = TutorInkColor.saved
    let save: (TutorConnection) throws -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("연결") {
                    TextField("튜터 서버 HTTPS 주소", text: $connection.server)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("튜터 서버 접속 토큰", text: $connection.token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section {
                    Toggle("튜터 서비스 사용", isOn: $connection.enabled)
                    Toggle("필기 후 자동 제안", isOn: $connection.automatic)
                        .disabled(!connection.enabled)
                    Picker("자동 제안 민감도", selection: $connection.sensitivity) {
                        ForEach(TutorSensitivity.allCases, id: \.self) { sensitivity in
                            Text(sensitivity.title).tag(sensitivity)
                        }
                    }
                    .disabled(!connection.enabled || !connection.automatic)
                }
                Section("판서 모양") {
                    Picker("글씨 크기", selection: $letterSize) {
                        ForEach(TutorLetterSize.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("판서 색상", selection: $inkColor) {
                        ForEach(TutorInkColor.allCases) { Text($0.title).tag($0) }
                    }
                }
                Section("필기 전송과 보관") {
                    Text("튜터는 화면에 보이는 일부 필기 이미지와 관련 인식 기록을 HTTPS로 서버에 보내며, 서버는 이를 BAZE로 전달합니다. 해당 영역에 PDF가 있으면 문제 원문도 이미지에 포함됩니다. 조용히 모드에서는 직접 질문할 때만 전송합니다.")
                    Text("튜터 응답은 서버 설정에 따라 일시적으로 메모리에 보관됩니다. 확정된 인식 기록과 승인한 판서는 현재 노트와 SQLite 백업에 포함됩니다.")
                    if let policy = URL(string: "https://baze.co/legal/privacy/") {
                        Link("BAZE 개인정보처리방침", destination: policy)
                    }
                }
                if invalid {
                    Text("HTTPS 주소와 튜터 서버 접속 토큰을 확인해 주세요.")
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle("튜터 연결")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("저장", action: saveConnection) }
            }
        }
    }

    private func saveConnection() {
        connection.server = connection.server.trimmingCharacters(in: .whitespacesAndNewlines)
        connection.token = connection.token.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try save(connection)
            UserDefaults.standard.set(letterSize.rawValue, forKey: TutorLetterSize.defaultsKey)
            UserDefaults.standard.set(inkColor.rawValue, forKey: TutorInkColor.defaultsKey)
            dismiss()
        } catch { invalid = true }
    }
}

@MainActor
struct TutorExampleView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var note: DrawingDocument?
    @State private var openFailed = false
    @StateObject private var navigation = CanvasNavigation()

    var body: some View {
        NavigationStack {
            Group {
                if let note {
                    ContentView(document: note, navigation: navigation, inTutorExample: true)
                } else if openFailed {
                    ContentUnavailableView("판서 예제를 열 수 없습니다", systemImage: "exclamationmark.triangle")
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("판서 예제")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("닫기") { dismiss() }
                    .accessibilityIdentifier("tutor.closeExample")
            }
        }
        .task {
            guard note == nil else { return }
            do { note = try TutorExample.open() }
            catch { openFailed = true }
        }
    }
}

@MainActor
enum TutorExample {
    static let answerID = UUID(uuid: (0xd0, 0x18, 0x30, 0x9e, 0x91, 0x72, 0x42, 0x7c,
                                     0xb8, 0x54, 0x6a, 0xdb, 0xab, 0x2e, 0x68, 0x0d))

    static func open() throws -> DrawingDocument {
        let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                    appropriateFor: nil, create: true)
        var name = "TutorExample"
        #if DEBUG && (targetEnvironment(simulator) || REEDLE_UI_TEST_SUPPORT)
        if let testID = ProcessInfo.processInfo.environment["REEDLE_UI_TEST_ID"], let id = UUID(uuidString: testID) {
            name += "-\(id.uuidString)"
        }
        #endif
        let folder = documents.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("drawing.pkdrawing")
        let store = try NoteStore(url: url.deletingPathExtension().appendingPathExtension("sqlite"))
        if try store.metadata().revision == 0 {
            // One native PencilKit archive per pen stroke in the example equation.
            let two = [CGPoint(x: 0, y: 11), .init(x: 7, y: 2), .init(x: 17, y: 0), .init(x: 28, y: 7),
                       .init(x: 28, y: 14), .init(x: 1, y: 36), .init(x: 31, y: 36)]
            let five = [CGPoint(x: 27, y: 0), .init(x: 4, y: 0), .init(x: 0, y: 18), .init(x: 14, y: 14),
                        .init(x: 27, y: 19), .init(x: 28, y: 28), .init(x: 23, y: 35), .init(x: 12, y: 38),
                        .init(x: 1, y: 33)]
            let strokes: [(CGFloat, CGFloat, [CGPoint])] = [
                (90, 128, two), (134, 146, [.zero, CGPoint(x: 24, y: 0)]),
                (146, 134, [.zero, CGPoint(x: 0, y: 24)]), (175, 128, two),
                (219, 140, [.zero, CGPoint(x: 25, y: 0)]), (219, 152, [.zero, CGPoint(x: 25, y: 0)]),
                (265, 128, five)
            ]
            let records = strokes.enumerated().map { index, line -> StoredStroke in
                let points = line.2.enumerated().map { offset, location in
                    PKStrokePoint(location: location, timeOffset: Double(offset) / 60,
                                  size: CGSize(width: 3.2, height: 3.2), opacity: 1, force: 0.7,
                                  azimuth: 0.4, altitude: 1.2)
                }
                let path = PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: Double(index + 1)))
                let stroke = PKStroke(ink: PKInk(.pen, color: .black), path: path, transform: .identity, mask: nil)
                return StoredStroke(id: index == strokes.count - 1 ? answerID : UUID(),
                                    bounds: stroke.renderBounds.offsetBy(dx: line.0, dy: line.1), zIndex: Int64(index),
                                    data: PKDrawing(strokes: [stroke]).dataRepresentation())
            }
            try store.commit(upserts: records)
        }
        return DrawingDocument(fileURL: url)
    }

    static func proposal(in document: DrawingDocument) throws -> TutorProposal {
        let request = try document.makeTutorContext(around: [answerID])
        let response = TutorResponse(schemaVersion: 1, requestID: request.requestID, noteID: request.noteID,
                                     observedRevision: request.inkRevision, decision: .act, actions: [
            TutorAction(id: UUID(), kind: .draw, targetID: answerID, intent: .onTarget, content: "circle"),
            TutorAction(id: UUID(), kind: .askQuestion, targetID: answerID, intent: .nearRight,
                        content: "2 + 2를 다시 계산해 볼래?")
        ])
        guard let proposal = try TutorProposal.decode(JSONEncoder().encode(response), for: request,
                                                       model: "예제 답변", reason: "마지막 값 다시 확인") else {
            throw TutorProposalError.invalidResponse
        }
        return proposal
    }
}
